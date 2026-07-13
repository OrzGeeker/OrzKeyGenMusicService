#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>

#include <sidplayfp/sidplayfp.h>
#include <sidplayfp/SidTune.h>
#include <sidplayfp/SidConfig.h>
#include <sidplayfp/SidTuneInfo.h>

extern "C" {
#include "audio_engine.h"
}

// ── 单例状态 ──
static sidplayfp *player = nullptr;
static SidTune *tune = nullptr;
static short *mix_buf = nullptr;
static unsigned int mix_buf_size = 0;
static double song_length_ms = 0;
static const unsigned int SAMPLE_RATE = 44100;

// ── Decoder 接口实现 ──

static int impl_load(const unsigned char *data, int len) {
    try {
    // 清理已有状态
    delete player; player = nullptr;
    delete tune; tune = nullptr;
    free(mix_buf); mix_buf = nullptr; mix_buf_size = 0;
    song_length_ms = 0;

    // 从内存加载 SID 文件 - 首先尝试直接创建
    tune = new(std::nothrow) SidTune(data, (uint_least32_t)len);
    if (!tune) return 0;

    if (!tune->getStatus()) {
        delete tune; tune = nullptr;
        return 0;
    }

    // 创建播放器
    player = new(std::nothrow) sidplayfp();
    if (!player) {
        delete tune; tune = nullptr;
        return 0;
    }

    // 配置：44100Hz
    SidConfig cfg;
    cfg.frequency = SAMPLE_RATE;
    if (!player->config(cfg)) {
        const char *err = player->error();
        delete player; player = nullptr;
        delete tune; tune = nullptr;
        return 0;
    }

    // 加载曲目
    if (!player->load(tune)) {
        const char *err = player->error();
        delete player; player = nullptr;
        delete tune; tune = nullptr;
        return 0;
    }

    // 初始化混音器（立体声）
    player->initMixer(true);

    song_length_ms = 180000.0;

    return 1;
    } catch (...) { return 0; }
}

static double impl_get_duration() {
    return song_length_ms / 1000.0;
}

static int impl_get_sample_rate() {
    return SAMPLE_RATE;
}

static int impl_get_channels() {
    return 2; // 立体声
}

static int impl_render(float *out, int frames) {
    if (!player) return 0;

    // 确保混音缓冲区足够大
    unsigned int needed = (unsigned int)frames;
    if (needed > mix_buf_size) {
        short *nb = (short *)realloc(mix_buf, needed * 2 * sizeof(short)); // 立体声 * 2
        if (!nb) return 0;
        mix_buf = nb;
        mix_buf_size = needed;
    }

    unsigned int total_rendered = 0;
    while (total_rendered < (unsigned int)frames) {
        // 每次播放 ~20ms 的 cycles (44100Hz → 882 samples → ~2048 cycles @ ~0.043ns/cycle)
        // 实际用 SID 时钟频率 ~985248 Hz，每 sample 约 22.3 cycles
        unsigned int cycles_per_frame = (SAMPLE_RATE > 0) ? (985248 / SAMPLE_RATE) : 22;
        unsigned int cycles = cycles_per_frame * (frames - (int)total_rendered);

        int samples = player->play(cycles);
        if (samples <= 0) break;

        // 获取各 SID 芯片的缓冲区
        short *chip_buffers[1];
        player->buffers(chip_buffers);

        // 混音到输出缓冲区
        unsigned int mixed = player->mix(mix_buf + total_rendered * 2, (unsigned int)samples);
        total_rendered += mixed;
    }

    // short → float 转换
    for (unsigned int i = 0; i < total_rendered * 2; i++) {
        out[i] = mix_buf[i] / 32768.0f;
    }

    return (int)total_rendered;
}

static void impl_destroy() {
    delete player; player = nullptr;
    delete tune; tune = nullptr;
    free(mix_buf); mix_buf = nullptr; mix_buf_size = 0;
    song_length_ms = 0;
}

// ── 导出 Decoder 实例（C 链接）──
extern "C" const Decoder decoder_sidplayfp = {
    "libsidplayfp",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy
};
