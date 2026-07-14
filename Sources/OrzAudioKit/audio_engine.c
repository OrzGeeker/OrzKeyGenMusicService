#include <emscripten.h>
#include <string.h>
#include "audio_engine.h"

// ── 导入各解码器的实例 ──
extern const Decoder decoder_openmpt;

// Game Music Emu (NSF/SPC)
extern const Decoder decoder_gme;

// ASAP (SAP — Atari POKEY 格式)
extern const Decoder decoder_asap;

// libsidplayfp (SID) — C++ 运行时兼容待排查
// extern const Decoder decoder_sidplayfp;


// ── 解码器自动注册 ──
static int registered = 0;

__attribute__((used)) void register_all() {
    if (registered) return;
    registered = 1;

    // libopenmpt: 模块跟踪器格式
    orz_register_decoder("xm,mod,it,s3m,mo3,mtm", &decoder_openmpt);

    // Game Music Emu: 游戏音乐格式 (nsf, spc)
    orz_register_decoder("nsf,spc", &decoder_gme);

    // ASAP: Atari POKEY 格式
    orz_register_decoder("sap", &decoder_asap);

    // libsidplayfp: Commodore 64 SID 格式 — 待修复
    // orz_register_decoder("sid", &decoder_sidplayfp);
}

// ── orz_audio_can_decode（保留，供 JS 调用）──
EMSCRIPTEN_KEEPALIVE
int orz_audio_can_decode(const char *extension) {
    register_all();
    return orz_can_decode(extension);
}
