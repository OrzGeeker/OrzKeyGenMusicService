#include <emscripten.h>
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

// adplug (AdLib OPL2/3: rad, d00, hsc)
extern const Decoder decoder_adplug;


// ── 解码器自动注册 ──
static int registered = 0;

__attribute__((used)) void register_all() {
    if (registered) return;
    registered = 1;

    // libopenmpt: 模块跟踪器格式
    orz_register_decoder("xm,mod,it,s3m,mo3,mtm,fc13,fc14", &decoder_openmpt);

    // Game Music Emu: 游戏音乐格式 (nsf, spc)
    orz_register_decoder("nsf,spc", &decoder_gme);

    // ASAP: Atari POKEY 格式
    orz_register_decoder("sap", &decoder_asap);

    // libsidplayfp: Commodore 64 SID 格式
    orz_register_decoder("sid", &decoder_sidplayfp);

    // v2m-player: Farbrausch V2 合成器格式
    orz_register_decoder("v2m", &decoder_v2m);

    // libsc68: Atari ST YM / Amiga 格式 (sc68=120首可播, ym=21首需LHa解压+格式转换)
    orz_register_decoder("sc68", &decoder_sc68);

    // adplug: AdLib OPL2/3 格式 (rad, d00, hsc)
    orz_register_decoder("rad,d00,hsc", &decoder_adplug);
}

// ── orz_audio_can_decode（保留，供 JS 调用）──
EMSCRIPTEN_KEEPALIVE
int orz_audio_can_decode(const char *extension) {
    register_all();
    return orz_can_decode(extension);
}
