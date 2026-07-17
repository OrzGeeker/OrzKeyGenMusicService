/**
 * paula_stubs.c — Paula audio I/O stubs for native sc68 decoder
 *
 * sc68 uses the io68 plugin system for hardware I/O through the
 * EMU68ioplug() call in api68_init(). The YM-2149 (Atari ST) format
 * does not need Paula audio output, but the library still references
 * the `paula_io` io68_t structure and mixer functions.
 *
 * This file provides no-op stubs so the linker resolves them and the
 * runtime never crashes when io68 iterates the plugin chain.
 *
 * Note: the WASM build generates a similar paula_stubs.c inline in
 * build-wasm.sh's generate_wrapper().
 */
#include <stdint.h>
#include <stddef.h>

/* ── Type definitions matching emu68/type68.h + emu68/struct68.h ── */
typedef uint32_t u32;
typedef unsigned int cycle68_t;

typedef struct {
    int vector;
    int level;
} int68_t;

#define IO68_NO_INT (0x80000000)

typedef u32 (*memrfunc68_t)(u32 addr, cycle68_t cycle);
typedef void (*memwfunc68_t)(u32 addr, u32 value, cycle68_t cycle);

typedef struct _io68_t {
    struct _io68_t *next;
    char name[32];
    u32 addr_low;
    u32 addr_high;
    memrfunc68_t Rfunc[3];
    memwfunc68_t Wfunc[3];
    int68_t *(*interrupt)(cycle68_t);
    cycle68_t (*next_int)(cycle68_t);
    void (*adjust_cycle)(cycle68_t);
    int (*reset)(void);
    cycle68_t rcycle_penalty;
    cycle68_t wcycle_penalty;
} io68_t;

/* ── No-op I/O handlers ── */
static u32 stub_readB(u32 a, cycle68_t c) { (void)a; (void)c; return 0; }
static u32 stub_readW(u32 a, cycle68_t c) { (void)a; (void)c; return 0; }
static u32 stub_readL(u32 a, cycle68_t c) { (void)a; (void)c; return 0; }
static void stub_writeB(u32 a, u32 v, cycle68_t c) { (void)a; (void)v; (void)c; }
static void stub_writeW(u32 a, u32 v, cycle68_t c) { (void)a; (void)v; (void)c; }
static void stub_writeL(u32 a, u32 v, cycle68_t c) { (void)a; (void)v; (void)c; }
static int68_t *stub_int(cycle68_t c) { (void)c; return 0; }
static cycle68_t stub_nextint(cycle68_t c) { (void)c; return IO68_NO_INT; }
static void stub_subcycle(cycle68_t s) { (void)s; }
static int stub_reset(void) { return 0; }

/* ── Paula I/O structure (all function pointers non-NULL) ── */
io68_t paula_io = { NULL, "Paula(stub)", 0xFFDFF000, 0xFFDFF0DF,
    {stub_readB, stub_readW, stub_readL},
    {stub_writeB, stub_writeW, stub_writeL},
    stub_int, stub_nextint, stub_subcycle, stub_reset, 0, 0 };

/* ── Paula mixer stubs (YM-only sc68 files do not use these) ── */
unsigned int PL_sampling_rate(unsigned int r) { return r; }
int PL_reset(void) { return 0; }
int PL_init(void) { return 0; }
void PL_mix(uint32_t *b, uint8_t *m, int n) { (void)b; (void)m; (void)n; }
