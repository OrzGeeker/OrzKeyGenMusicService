/**
 * uade_wasm.c — UADE (UAE Amiga Emulator) WASM Decoder
 *
 * Plays AHX, AMD and other Amiga music formats by running the actual
 * Amiga player binary inside a 68000 emulator (UAE core).
 *
 * Architecture:
 *   Instead of the normal uade IPC protocol (uadecore ↔ libuade pipes),
 *   this wrapper initializes the UAE core directly and provides audio
 *   via the standard OrzAudioKit Decoder interface.
 *
 * Embedded binaries:
 *   - score: Amiga sound core binary (runs on the emulated Amiga)
 *   - player: Amiga player binary (e.g. AbyssHighestExperience for AHX)
 *   - module: the actual music file data (passed to impl_load)
 */

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <arpa/inet.h>

/* ── UAE core headers ── */
#include "sysconfig.h"
#include "sysdeps.h"
#include "options.h"
#include "uae.h"
#include "memory.h"
#include "custom.h"
#include "readcpu.h"
#include "newcpu.h"
#include "events.h"
#include "gensound.h"
#include "sd-sound.h"
#include "audio.h"
#include "cia.h"
#include "uadectl.h"
#include "amigamsg.h"
#include "write_audio.h"

#include "audio_engine.h"

/* ── Embedded binary data ── */
#include "score_data.h"
#include "ahx_player_data.h"

/* ══════════════════════════════════════════════════════════════════
   UAE Core Global Variables (normally in uademain.c / uade.c)
   ══════════════════════════════════════════════════════════════════ */

struct uae_prefs currprefs, changed_prefs;

int no_gui = 1;
int joystickpresent = 0;
int cloanto_rom = 0;
char warning_buffer[256];
int quit_program = 0;

/* UADE-specific globals (normally in uade.c) */
int uadecore_audio_output = 0;
int uadecore_audio_start_slow = 0;
int uadecore_audio_skip = 0;
int uadecore_debug = 0;
int uadecore_read_size = 0;
int uadecore_reboot = 0;
int uadecore_time_critical = 0;
int uadecore_has_been_booted = 0;

struct uade_ipc uadecore_ipc;   /* unused in WASM mode */
struct uade_song song;

/* ══════════════════════════════════════════════════════════════════
   WASM Audio Buffer State
   ══════════════════════════════════════════════════════════════════ */

static float  *wasm_output     = NULL;
static int     wasm_output_pos = 0;
static int     wasm_output_cap = 0;       /* in stereo floats */
static int     wasm_frames_rdy = 0;
static int     wasm_module_loaded = 0;

/* ══════════════════════════════════════════════════════════════════
   Helper Functions (from uade.c, minus IPC)
   ══════════════════════════════════════════════════════════════════ */

/* Score / uade memory-mapped addresses (must match uade score binary) */
#define SCORE_MODULE_ADDR     0x100
#define SCORE_MODULE_LEN      0x104
#define SCORE_PLAYER_ADDR     0x108
#define SCORE_RELOC_ADDR      0x10C
#define SCORE_USER_STACK      0x110
#define SCORE_SUPER_STACK     0x114
#define SCORE_FORCE           0x118
#define SCORE_SET_SUBSONG     0x11C
#define SCORE_SUBSONG         0x120
#define SCORE_NTSC            0x124
#define SCORE_MODULE_NAME_ADDR  0x128
#define SCORE_HAVE_SONGEND    0x12C
#define SCORE_POSTPAUSE       0x180
#define SCORE_PREPAUSE        0x184
#define SCORE_DELIMON         0x188
#define SCORE_EXEC_DEBUG      0x18C
#define SCORE_MODULECHANGE    0x198
#define UADECORE_INPUT_MSG    0x200
#define SCORE_MIN_SUBSONG     0x204
#define SCORE_MAX_SUBSONG     0x208
#define SCORE_CUR_SUBSONG     0x20C
#define SCORE_INPUT_MSG       0x300
#define MODULE_NAME_ADDR      0x00400
#define SCORE_ADDR            0x01000
#define USER_STACK_ADDR       0x08500
#define SUPER_STACK_ADDR      0x08F00
#define PLAYER_ADDR           0x09000

static int highmem = 0;

static inline uae_u32 amiga_get_u32(int addr)
{
    if (addr + 4 > allocated_chipmem) return 0;
    uae_u32 v;
    memcpy(&v, chipmemory + addr, 4);
    return ntohl(v);
}

static inline int amiga_get_i32(int addr)
{
    return (int)amiga_get_u32(addr);
}

static void uade_put_long(int addr, int val)
{
    if (addr + 4 > allocated_chipmem) return;
    uae_u32 nv = htonl((uae_u32)val);
    memcpy(chipmemory + addr, &nv, 4);
}

static int uade_safe_copy(int dst, const void *buf, size_t buflen)
{
    int maxlen = (int)allocated_chipmem - dst;
    if (maxlen <= 0) return 0;
    if (buflen > (size_t)maxlen) {
        buflen = (size_t)maxlen;
    }
    memcpy(chipmemory + dst, buf, buflen);
    return (int)buflen;
}

/* Calculate relocation size for AmigaOS loadseg() hunk format */
static int calc_reloc_size(const uae_u32 *src, const uae_u32 *end)
{
    if (src >= end) return 0;
    if (ntohl(*src) != 0x000003f3) return 0;  /* HUNK_HEADER */
    src++;
    if (src >= end) return 0;
    if (ntohl(*src) != 0) return 0;            /* HUNK_UNIT (or 0 for loadseg) */
    src++;
    if (src >= end) return 0;

    int nhunks = ntohl(*src) & 0xffff;
    if (nhunks == 0) return 0;
    src += 3;  /* skip nhunks + first + last */

    int offset = 0;
    for (int i = 0; i < nhunks; i++) {
        if (src >= end) return 0;
        offset += 4 * (ntohl(*src) & 0x00FFFFFF);
        src++;
    }

    if (offset <= 0 || offset >= (int)allocated_chipmem)
        return 0;
    return offset;
}

/* ══════════════════════════════════════════════════════════════════
   uadecore function replacements (originally in uade.c)
   ══════════════════════════════════════════════════════════════════ */

void uadecore_send_debug(const char *fmt, ...)
{
    (void)fmt;  /* no-op in WASM */
}

void uadecore_swap_buffer_bytes(void *data, int bytes)
{
    if (!data || bytes <= 0) return;
    uint8_t *buf = (uint8_t *)data;
    for (int i = 0; i < bytes; i += 2) {
        uint8_t tmp = buf[i];
        buf[i] = buf[i + 1];
        buf[i + 1] = tmp;
    }
}

void uadecore_send_message_to_amiga(int msgtype)
{
    uade_put_long(SCORE_INPUT_MSG, msgtype);
}

void uadecore_set_ntsc(int usentsc)
{
    uade_put_long(SCORE_NTSC, usentsc);
}

void uadecore_set_automatic_song_end(int song_end_possible)
{
    uade_put_long(SCORE_HAVE_SONGEND, song_end_possible);
}

void uadecore_song_end(char *reason, int kill_it)
{
    (void)reason; (void)kill_it;
    uadecore_audio_output = 0;
}

/* Called on trap #5 from Amiga score */
void uadecore_get_amiga_message(void)
{
    int amigamsg = amiga_get_i32(UADECORE_INPUT_MSG);

    switch (amigamsg) {
    case AMIGAMSG_SONG_END:
        uadecore_song_end("player", 0);
        break;
    case AMIGAMSG_START_OUTPUT:
        uadecore_audio_output = 1;
        break;
    default:
        break;
    }

    uade_put_long(UADECORE_INPUT_MSG, 0);
}

/* Audio buffer flush — called from audio event handler when buffer is full.
   Instead of sending via IPC, we copy to the WASM output buffer. */
void uadecore_check_sound_buffers(int bytes)
{
    if (uadecore_reboot) {
        sndbufpt = sndbuffer;
        return;
    }
    if (!wasm_output || wasm_output_cap <= 0) {
        sndbufpt = sndbuffer;
        return;
    }

    int samples = bytes / 2;    /* uae_u16 samples */
    int max_out = wasm_output_cap;
    int to_copy = samples;
    if (wasm_output_pos + to_copy > max_out)
        to_copy = max_out - wasm_output_pos;

    /* Convert big-endian 16-bit signed samples to interleaved float */
    for (int i = 0; i < to_copy; i += 2) {
        int16_t l = (int16_t)((sndbuffer[i] >> 8) | (sndbuffer[i] << 8));
        int16_t r = (int16_t)((sndbuffer[i+1] >> 8) | (sndbuffer[i+1] << 8));
        wasm_output[wasm_output_pos++] = l / 32768.0f;
        wasm_output[wasm_output_pos++] = r / 32768.0f;
    }

    wasm_frames_rdy = wasm_output_pos / 2;
    sndbufpt = sndbuffer;

    /* Signal the emulator to stop if we filled the output buffer */
    if (wasm_output_pos >= wasm_output_cap) {
        uadecore_reboot = 1;
    }
}

/* Handle R state — normally receives frontend commands via IPC.
   In WASM mode there are no IPC commands, so this is a no-op. */
void uadecore_handle_r_state(void)
{
    /* no-op */
}

/* ══════════════════════════════════════════════════════════════════
   UAE Initialisation (replaces uademain.c)
   ══════════════════════════════════════════════════════════════════ */

void default_prefs(struct uae_prefs *p)
{
    memset(p, 0, sizeof(*p));
    p->produce_sound   = 3;     /* sound enabled */
    p->stereo          = 1;
    p->sound_bits      = 16;
    p->sound_freq      = 44100;
    p->chipmem_size    = 0x00200000;  /* 2 MB chip RAM */
    p->fastmem_size    = 0;
    p->bogomem_size    = 0;
    p->m68k_speed      = 0;     /* max speed */
    p->cpu_level       = 0;     /* 68000 */
    p->cpu_compatible  = 1;
    p->address_space_24 = 1;
    p->illegal_mem     = 0;
}

static int uae_initialised = 0;

static int init_uae_core(void)
{
    if (uae_initialised) return 1;

    default_prefs(&currprefs);
    machdep_init();               /* empty on most platforms */
    setup_sound();                /* always returns 1 */
    init_sound();

    changed_prefs = currprefs;
    check_prefs_changed_cpu();

    memory_init();
    custom_init();
    reset_frame_rate_hack();
    init_m68k();

    highmem = (int)allocated_chipmem;
    uae_initialised = 1;
    return 1;
}

/* ══════════════════════════════════════════════════════════════════
   Load song into Amiga memory (replaces uadecore_reset minus IPC)
   ══════════════════════════════════════════════════════════════════ */

static int load_song(const unsigned char *module_data, int module_len)
{
    if (!uae_initialised) return 0;

    /* Protect the stack areas */
    const uae_u8 wall[] = {'W','A','L','L'};

    /* Clear Amiga memory */
    if (highmem < 0x80000) return 0;
    memset(chipmemory, 0, (size_t)highmem);

    /* Write stack guards */
    memcpy(chipmemory + SUPER_STACK_ADDR, wall, 4);
    memcpy(chipmemory + USER_STACK_ADDR,  wall, 4);

    /* ── Load player binary at PLAYER_ADDR (0x9000) ── */
    int player_size = ahx_player_bin_len;
    if (!player_size) return 0;

    int copied = uade_safe_copy(PLAYER_ADDR, ahx_player_bin, (size_t)player_size);
    if (copied <= 0) return 0;

    /* Set player address for relocator */
    uade_put_long(SCORE_PLAYER_ADDR, PLAYER_ADDR);

    /* Calculate relocation size */
    int reloc_size = calc_reloc_size(
        (const uae_u32 *)(chipmemory + PLAYER_ADDR),
        (const uae_u32 *)(chipmemory + PLAYER_ADDR + copied));

    if (!reloc_size) return 0;

    /* Calculate module address (rounded up from end of player + reloc) */
    int reloc_addr = ((PLAYER_ADDR + copied) & 0x7FFFF000) + 0x4000;
    int mod_addr   = ((reloc_addr + reloc_size) & 0x7FFFF000) + 0x2000;

    uade_put_long(SCORE_RELOC_ADDR, reloc_addr);
    uade_put_long(SCORE_MODULE_ADDR, mod_addr);
    uade_put_long(SCORE_MODULE_LEN, 0);
    uade_put_long(SCORE_MODULE_NAME_ADDR, 0);

    /* ── Load module data ── */
    if (module_data && module_len > 0) {
        copied = uade_safe_copy(mod_addr, module_data, (size_t)module_len);
        if (copied <= 0) return 0;
        uade_put_long(SCORE_MODULE_LEN, copied);

        /* Write module name */
        const char *mod_name = "song.ahx";
        if (mod_addr > MODULE_NAME_ADDR) {
            memcpy(chipmemory + MODULE_NAME_ADDR, mod_name, strlen(mod_name) + 1);
            uade_put_long(SCORE_MODULE_NAME_ADDR, MODULE_NAME_ADDR);
        }
    }

    /* ── Load score binary at SCORE_ADDR (0x1000) ── */
    copied = uade_safe_copy(SCORE_ADDR, score_bin, (size_t)score_bin_len);
    if (copied <= 0) return 0;

    /* ── Set up CPU state for score execution ── */
    m68k_areg(regs, 7) = SCORE_ADDR;            /* A7 = stack */
    m68k_setpc(SCORE_ADDR);                      /* PC = score entry */

    /* Configuration for score */
    uade_put_long(SCORE_EXEC_DEBUG, 0);
    uade_put_long(SCORE_MODULECHANGE, 0);
    uade_put_long(SCORE_FORCE, 0);
    uade_put_long(SCORE_SET_SUBSONG, 0);
    uade_put_long(SCORE_SUBSONG, 0);
    uadecore_set_ntsc(0);
    uadecore_set_automatic_song_end(1);
    uade_put_long(SCORE_PREPAUSE, 0);
    uade_put_long(SCORE_POSTPAUSE, 0);
    uade_put_long(SCORE_USER_STACK, USER_STACK_ADDR);
    uade_put_long(SCORE_SUPER_STACK, SUPER_STACK_ADDR);
    uade_put_long(SCORE_INPUT_MSG, 0);

    /* Reset state */
    uadecore_audio_output = 0;
    uadecore_reboot = 0;
    uadecore_read_size = 4096;   /* request 4096 bytes = 1024 stereo frames */
    set_sound_freq(44100);
    flush_sound();

    uadecore_has_been_booted = 1;
    return 1;
}

/* ══════════════════════════════════════════════════════════════════
   Decoder Interface Implementation
   ══════════════════════════════════════════════════════════════════ */

static struct {
    unsigned char *module;
    int            module_len;
    int            loaded;
} uade_state = {NULL, 0, 0};

static int impl_load(const unsigned char *data, int len)
{
    /* Free previous module */
    if (uade_state.module) {
        free(uade_state.module);
        uade_state.module = NULL;
    }

    /* Initialise UAE core on first load */
    if (!init_uae_core()) return 0;

    /* Copy module data (WASM heap may be freed by caller) */
    uade_state.module = (unsigned char *)malloc((size_t)len);
    if (!uade_state.module) return 0;
    memcpy(uade_state.module, data, (size_t)len);
    uade_state.module_len = len;

    /* Load song into Amiga emulator memory */
    if (!load_song(uade_state.module, uade_state.module_len)) {
        free(uade_state.module);
        uade_state.module = NULL;
        return 0;
    }

    /* Reset CPU and custom chips (same as original m68k_go sequence) */
    m68k_reset();
    customreset();

    uade_state.loaded = 1;
    return 1;
}

static double impl_get_duration(void)
{
    /* UAE-based decoders don't know duration in advance.
       We return a generous default; player.js can update on song end. */
    return 180.0;
}

static int impl_get_sample_rate(void) { return 44100; }
static int impl_get_channels(void)   { return 2; }

static int impl_render(float *out, int frames)
{
    if (!uade_state.loaded || !out || frames <= 0) return 0;

    wasm_output     = out;
    wasm_output_cap = frames * 2;   /* stereo interleaved */
    wasm_output_pos = 0;
    wasm_frames_rdy = 0;

    /* Run the emulator: m68k_run_1() loops until uadecore_reboot is set.
       Our uadecore_check_sound_buffers() sets uadecore_reboot=1 when the
       output buffer is full or the song ends. We then reset it and call
       again if more audio is needed. */
    int safety = 100000;
    while (wasm_frames_rdy < frames && !quit_program && --safety > 0) {
        uadecore_reboot = 0;
        m68k_run_1();

        /* Flush any pending audio that didn't reach uadecore_read_size */
        intptr_t buf_bytes = (intptr_t)sndbufpt - (intptr_t)sndbuffer;
        if (buf_bytes > 0 && uadecore_audio_output) {
            uadecore_check_sound_buffers((int)buf_bytes);
        }
    }

    wasm_output     = NULL;
    wasm_output_cap = 0;

    return wasm_frames_rdy;
}

static void impl_destroy(void)
{
    if (uade_state.module) {
        free(uade_state.module);
        uade_state.module = NULL;
    }
    uade_state.module_len = 0;
    uade_state.loaded = 0;
    wasm_output = NULL;
    wasm_output_cap = 0;
    wasm_output_pos = 0;
    wasm_frames_rdy = 0;

    /* Free UAE chipmem */
    if (chipmemory) {
        free(chipmemory);
        chipmemory = NULL;
    }
    allocated_chipmem = 0;
    highmem = 0;
    uae_initialised = 0;
}

/* ══════════════════════════════════════════════════════════════════
   Logging stubs (uade_logging.c uses libzakalwe — not available in WASM)
   ══════════════════════════════════════════════════════════════════ */

void uade_logging_str(const char *s) { (void)s; }
void uade_logging_flush(void) {}

/* write_log_standard — called as write_log (via target.h #define) */
void write_log_standard(const char *fmt, ...) { (void)fmt; }

/* Debugger stubs (debug.c not compiled for WASM) */
int debugging = 0;
int debug_interrupt_happened = 0;
void activate_debugger(void) {}
void debug(void) {}

/* write_audio.c stubs — audio captured directly from sndbuffer instead */

/* These functions are declared in write_audio.h; we provide empty stubs
   because audio is captured from sndbuffer instead of write_audio system. */
struct uade_write_audio *uade_write_audio_init(const char *fname, const int fd)
    { (void)fname; (void)fd; return NULL; }
void uade_write_audio_write(struct uade_write_audio *w, const int output[4],
    const unsigned long tdelta) { (void)w; (void)output; (void)tdelta; }
void uade_write_audio_write_left_right(struct uade_write_audio *w,
    const int left, const int right) { (void)w; (void)left; (void)right; }
void uade_write_audio_set_state(struct uade_write_audio *w, const int channel,
    const enum UADEPaulaEventType event_type, const uint16_t value)
    { (void)w; (void)channel; (void)event_type; (void)value; }
void uade_write_audio_close(struct uade_write_audio *w) { (void)w; }

/* IPC stubs — no inter-process communication in WASM */
int uade_send_string(enum uade_msgtype com, const char *str, struct uade_ipc *ipc)
    { (void)com;(void)str;(void)ipc; return 0; }
int uade_send_message(struct uade_msg *um, struct uade_ipc *ipc)
    { (void)um;(void)ipc; return 0; }
int uade_send_short_message(enum uade_msgtype msgtype, struct uade_ipc *ipc)
    { (void)msgtype;(void)ipc; return 0; }
int uade_receive_message(struct uade_msg *um, size_t maxbytes, struct uade_ipc *ipc)
    { (void)um;(void)maxbytes;(void)ipc; return 0; }
int uade_receive_short_message(enum uade_msgtype msgtype, struct uade_ipc *ipc)
    { (void)msgtype;(void)ipc; return -1; }
int uade_receive_string(char *s, enum uade_msgtype com, size_t maxlen, struct uade_ipc *ipc)
    { (void)s;(void)com;(void)maxlen;(void)ipc; return 0; }
int uade_send_file(const struct uade_file *f, struct uade_ipc *ipc)
    { (void)f;(void)ipc; return 0; }
struct uade_file *uade_receive_file(struct uade_ipc *ipc)
    { (void)ipc; return NULL; }
void uade_set_peer(struct uade_ipc *ipc, int peer_is_client, int in_fd, int out_fd)
    { (void)ipc;(void)peer_is_client;(void)in_fd;(void)out_fd; }
int uade_send_u32(enum uade_msgtype com, uint32_t u, struct uade_ipc *ipc)
    { (void)com;(void)u;(void)ipc; return 0; }
int uade_parse_u32_message(uint32_t *u1, struct uade_msg *um)
    { (void)u1;(void)um; return -1; }
int uade_parse_two_u32s_message(uint32_t *u1, uint32_t *u2, struct uade_msg *um)
    { (void)u1;(void)u2;(void)um; return -1; }
void uade_check_fix_string(struct uade_msg *um, size_t maxlen)
    { (void)um;(void)maxlen; }

/* FPU stubs (no 68881/882 in minimal UAE — headers in newcpu.h declare void return) */
void fpp_opp(uae_u32 opcode, uae_u16 extra) { (void)opcode;(void)extra; }
void fdbcc_opp(uae_u32 opcode, uae_u16 extra) { (void)opcode;(void)extra; }
void fscc_opp(uae_u32 opcode, uae_u16 extra) { (void)opcode;(void)extra; }
void ftrapcc_opp(uae_u32 opcode, uaecptr pc) { (void)opcode;(void)pc; }
void fbcc_opp(uae_u32 opcode, uaecptr pc, uae_u32 extra) { (void)opcode;(void)pc;(void)extra; }
void fsave_opp(uae_u32 opcode) { (void)opcode; }
void frestore_opp(uae_u32 opcode) { (void)opcode; }

/* ══════════════════════════════════════════════════════════════════
   Decoder Interface
   ══════════════════════════════════════════════════════════════════ */

const Decoder decoder_uade = {
    "uade",
    impl_load, impl_get_duration,
    impl_get_sample_rate, impl_get_channels,
    impl_render, impl_destroy
};
