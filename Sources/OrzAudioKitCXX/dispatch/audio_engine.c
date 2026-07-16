#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#else
#define EMSCRIPTEN_KEEPALIVE
#endif
#include <string.h>
#include "audio_engine.h"

// ── 导入各解码器的实例 ──
extern const Decoder decoder_openmpt;

// Game Music Emu (NSF/SPC)
extern const Decoder decoder_gme;

// ASAP (SAP — Atari POKEY 格式)
extern const Decoder decoder_asap;

// libsidplayfp (SID)
extern const Decoder decoder_sidplayfp;

// libsc68 (Atari ST YM/Amiga)
extern const Decoder decoder_sc68;

// v2m-player (Farbrausch V2M)
extern const Decoder decoder_v2m;

// ym6 (Atari ST YM2149)
extern const Decoder decoder_ym6;

// uade (Amiga: ahx, thx)
extern const Decoder decoder_uade_ahx;

// adplug (AdLib OPL2/3: rad, d00, hsc)
extern const Decoder decoder_adplug;

// midi (wavetable synth)
extern const Decoder decoder_midi;


// ── 解码器自动注册 ──
static int registered = 0;

__attribute__((used)) __attribute__((noinline)) void register_all() {
    if (registered) return;
    registered = 1;

    // 只注册有真实实现的解码器（.load != NULL 表示非存根）
    // stub_decoders.c 提供 __attribute__((weak)) 零值存根，
    // 未编译的解码器所有函数指针为 NULL。

    if (decoder_openmpt.load)
        orz_register_decoder("xm,mod,it,s3m,mo3,mtm,fc13,fc14", &decoder_openmpt);

    if (decoder_gme.load)
        orz_register_decoder("nsf,spc", &decoder_gme);

    if (decoder_asap.load)
        orz_register_decoder("sap", &decoder_asap);

    if (decoder_sidplayfp.load)
        orz_register_decoder("sid", &decoder_sidplayfp);

    if (decoder_v2m.load)
        orz_register_decoder("v2m", &decoder_v2m);

    if (decoder_sc68.load)
        orz_register_decoder("sc68", &decoder_sc68);

    if (decoder_ym6.load)
        orz_register_decoder("ym", &decoder_ym6);

    if (decoder_uade_ahx.load)
        orz_register_decoder("ahx,thx", &decoder_uade_ahx);

    if (decoder_adplug.load)
        orz_register_decoder("rad,d00,hsc,amd", &decoder_adplug);

    if (decoder_midi.load)
        orz_register_decoder("mid", &decoder_midi);
}

// ── orz_audio_can_decode（保留，供 JS 调用）──
EMSCRIPTEN_KEEPALIVE
int orz_audio_can_decode(const char *extension) {
    register_all();
    return orz_can_decode(extension);
}
