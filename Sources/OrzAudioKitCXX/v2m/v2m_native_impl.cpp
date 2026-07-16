/**
 * v2m_native_impl.cpp — V2M 原生解码器
 *
 * 使用 jgilje/v2m-player 库的 V2MPlayer API。
 * 注意：V2MPlayer::Open() 要求数据指针在 player 生命周期内保持有效。
 * 因此 impl_load 必须复制输入数据到自有缓冲区。
 */
#include <stdlib.h>
#include <string.h>
#include "audio_engine.h"
#include "v2mplayer.h"

// ── 合成器状态 ──

static V2MPlayer *player = NULL;
static unsigned char *owned_data = NULL;  // V2MPlayer 只存指针，必须持有一份数据拷贝
static int owned_data_len = 0;
static int sample_rate = 44100;
static int channels = 2;
static int v2m_file_size = 0;            // 文件大小，用于 duration 降级判断
static int v2m_ended = 0;                // 歌曲结束后标记，后续 render 返回 0

// ── Decoder 接口 ──

static void impl_destroy(void);

static int impl_load(const unsigned char *data, int len) {
    impl_destroy();

    // 复制数据（V2MPlayer::Open 要求数据指针在 player 生命周期内有效）
    owned_data = (unsigned char *)malloc(len);
    if (!owned_data) return 0;
    memcpy(owned_data, data, len);
    owned_data_len = len;
    v2m_file_size = len;
    v2m_ended = 0;

    player = new V2MPlayer();
    if (!player) { free(owned_data); owned_data = NULL; return 0; }
    player->Init(1000);

    // Open 加载 .v2m 数据（使用拷贝后的数据）
    if (!player->Open(owned_data, sample_rate, false)) {
        delete player; player = NULL;
        free(owned_data); owned_data = NULL;
        return 0;
    }

    // Play 调用启动回放（必须在 load 时调用一次，不要在 render 重复调用，
    // 因为 V2MPlayer::Play() 内部会 Stop() + Reset()，重复调用会丢失进度）
    player->Play(0);

    return 1;
}

static double impl_get_duration(void) {
    if (!player) return 0;
    uint32_t len = player->Length();
    // Length() 返回毫秒。对于大文件（>10KB）但时长 <5s 的情况，
    // 可能是 Length() 不准确，使用 120 秒默认值确保能完整播放
    if (len < 5000 && v2m_file_size > 10240) {
        return 120.0;
    }
    return (len > 0) ? (double)len / 1000.0 : 0.0;
}

static int impl_get_sample_rate(void) { return sample_rate; }
static int impl_get_channels(void) { return channels; }

static int impl_render(float *out, int frames) {
    if (!player) return 0;

    // 歌曲已结束（上次检测到 IsPlaying=false），返回 0 让 JS 流式循环退出
    if (v2m_ended) return 0;

    // V2MPlayer::Render 输出 float32 stereo interleaved
    player->Render(out, frames, false);

    // 检测歌曲是否结束：Render 后检查 IsPlaying，若结束则标记并在下次返回 0
    if (!player->IsPlaying()) {
        v2m_ended = 1;
    }

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
    free(owned_data);
    owned_data = NULL;
    owned_data_len = 0;
    v2m_file_size = 0;
    v2m_ended = 0;
}

// ── 导出 Decoder 实例（必须 extern "C" 以覆盖 stub_decoders.c 的弱符号）──

extern "C"
const Decoder decoder_v2m = {
    "v2m-player-native",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy
};
