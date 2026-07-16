/**
 * v2m_native_impl.cpp — V2M 原生解码器
 *
 * 使用 jgilje/v2m-player 库的 V2MPlayer API。
 * 替换原 v2m_wasm.cpp（使用 Windows 类型 sU32 等）。
 */
#include <stdlib.h>
#include <string.h>
#include "audio_engine.h"
#include "v2mplayer.h"

// ── 合成器状态 ──

static V2MPlayer *player = NULL;
static int sample_rate = 44100;
static int channels = 2;

// ── Decoder 接口 ──

static void impl_destroy(void);

static int impl_load(const unsigned char *data, int len) {
    impl_destroy();

    player = new V2MPlayer();
    if (!player) return 0;
    player->Init(1000);

    // Open 加载 .v2m 数据
    if (!player->Open(data, sample_rate, false)) {
        delete player; player = NULL;
        return 0;
    }

    return 1;
}

static double impl_get_duration(void) {
    if (!player) return 0;
    uint32_t len = player->Length();
    return (len > 0) ? (double)len / 1000.0 : 0.0;
}

static int impl_get_sample_rate(void) { return sample_rate; }
static int impl_get_channels(void) { return channels; }

static int impl_render(float *out, int frames) {
    if (!player) return 0;

    // 首次渲染时启动播放
    static bool started = false;
    if (!started) {
        player->Play(0);
        started = true;
    }

    // V2MPlayer::Render 输出 float32 stereo interleaved
    player->Render(out, frames, false);

    // 音量衰减
    for (int i = 0; i < frames * 2; i++) {
        out[i] *= 0.3f;
    }

    return frames;
}

static void impl_destroy(void) {
    if (player) {
        player->Close();
        delete player;
        player = NULL;
    }
}

// ── 导出 Decoder 实例 ──

const Decoder decoder_v2m = {
    "v2m-player-native",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy
};
