#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>

#include <sidplayfp/sidplayfp.h>
#include <sidplayfp/SidTune.h>
#include <sidplayfp/SidConfig.h>
#include <sidplayfp/SidTuneInfo.h>
#include <sidplayfp/sidbuilder.h>
#include <sidplayfp/siddefs.h>

// sidlite 模拟器（内建于 libsidplayfp）
#include <sidlite.h>

extern "C" {
#include "audio_engine.h"
}

// ── 单例状态 ──
static sidplayfp *player = nullptr;
static SidTune *tune = nullptr;
static sidbuilder *sid_builder = nullptr;
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
    delete sid_builder; sid_builder = nullptr;
    free(mix_buf); mix_buf = nullptr; mix_buf_size = 0;
    song_length_ms = 0;

    // 从内存加载 SID 文件
    tune = new(std::nothrow) SidTune(data, (uint_least32_t)len);
    if (!tune) return 0;

    if (!tune->getStatus()) {
        delete tune; tune = nullptr;
        return 0;
    }

    // 创建 sidlite 模拟器
    sid_builder = new(std::nothrow) SIDLiteBuilder("sidlite");
    if (!sid_builder) {
        delete tune; tune = nullptr;
        return 0;
    }

    // 创建播放器
    player = new(std::nothrow) sidplayfp();
    if (!player) {
        delete sid_builder; sid_builder = nullptr;
        delete tune; tune = nullptr;
        return 0;
    }

    // 配置：44100Hz + sidlite 模拟器
    SidConfig cfg;
    cfg.frequency = SAMPLE_RATE;
    cfg.sidEmulation = sid_builder;
    if (!player->config(cfg)) {
        delete player; player = nullptr;
        delete sid_builder; sid_builder = nullptr;
        delete tune; tune = nullptr;
        return 0;
    }

    // 加载曲目（内部调用 config，重置引擎状态）
    if (!player->load(tune)) {
        delete player; player = nullptr;
        delete sid_builder; sid_builder = nullptr;
        delete tune; tune = nullptr;
        return 0;
    }

    // 重置引擎，再初始化混音器（立体声）
    // initMixer 需要在 reset() 之后调用，否则混音器状态被清除
    player->initMixer(true);
    player->reset();

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

    try {
    // 确保混音缓冲区足够大 (frames 个立体声帧 → frames * 2 个 short)
    unsigned int needed = (unsigned int)frames;
    if (needed > mix_buf_size) {
        short *nb = (short *)realloc(mix_buf, needed * 2 * sizeof(short));
        if (!nb) return 0;
        mix_buf = nb;
        mix_buf_size = needed;
    }

    // 分批渲染，每批最多 ~4096 帧，避免 cycles 计算溢出且控制单次 play() 耗时
    // 每帧 ~22.34 cycles，4096 帧 ≈ 91501 cycles
    const unsigned int BATCH_FRAMES = 4096;
    unsigned int total_rendered = 0;

    while (total_rendered < (unsigned int)frames) {
        unsigned int remaining = (unsigned int)frames - total_rendered;
        unsigned int batch = (remaining > BATCH_FRAMES) ? BATCH_FRAMES : remaining;

        // SID 时钟 ~985248 Hz，每帧需 cycles = 985248 / SAMPLE_RATE
        // 使用 64 位避免 32 位溢出
        unsigned long long cycles_64 = (unsigned long long)batch * 985248ULL / SAMPLE_RATE;
        if (cycles_64 < 1) cycles_64 = 1;
        unsigned int cycles = (unsigned int)cycles_64;

        int per_channel = player->play(cycles);
        if (per_channel <= 0) break;

        // mix() 将 SID 芯片缓冲区混音到输出，写入 interleaved stereo
        // 返回总样本数：mono=per_channel, stereo=per_channel*2
        unsigned int mixed = player->mix(
            mix_buf + total_rendered * 2,
            (unsigned int)per_channel
        );

        // stereo: mixed = per_channel * 2 → 实际帧数 = mixed / 2
        total_rendered += mixed / 2;
    }

    // short → float 转换 (interleaved stereo)
    for (unsigned int i = 0; i < total_rendered * 2; i++) {
        out[i] = mix_buf[i] / 32768.0f;
    }

    return (int)total_rendered;
    } catch (...) { return 0; }
}

static void impl_destroy() {
    delete player; player = nullptr;
    delete tune; tune = nullptr;
    delete sid_builder; sid_builder = nullptr;
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
