/**
 * sc68 decoder wrapper — Atari ST (YM) / Amiga formats
 *
 * Uses api68 API with inline replay data.
 * Output: 44100Hz stereo interleaved float32 PCM.
 */
#include <stdlib.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "audio_engine.h"
#include "api68/api68.h"

// ── 单例状态 ──
static api68_t *sc68 = NULL;
static api68_init_t init68;

// 适配 Emscripten 的 malloc 签名 (void*(unsigned long) vs void*(unsigned int))
static void *sc68_alloc(unsigned int size) { return malloc((size_t)size); }
static void sc68_free(void *p) { free(p); }
static int sample_rate = 44100;
static int duration_ms = 0;
static int buffer_samples = 0;
static int *pcm_buffer = NULL;

// ── inline replay data 注册 ──
extern void register_players(void);

// ── Decoder 接口实现 ──

static int impl_load(const unsigned char *data, int len)
{
    // 清理旧状态
    if (sc68) {
        api68_stop(sc68);
        api68_shutdown(sc68);
        sc68 = NULL;
    }
    free(pcm_buffer);
    pcm_buffer = NULL;
    buffer_samples = 0;
    duration_ms = 0;

    // 注册 inline replay modules
    register_players();

    // 初始化 API
    memset(&init68, 0, sizeof(init68));
    init68.alloc = sc68_alloc;
    init68.free = sc68_free;
    init68.sampling_rate = sample_rate;

    sc68 = api68_init(&init68);
    if (!sc68) return 0;

    // 验证文件格式
    if (api68_verify_mem((const void*)data, len) < 0) {
        api68_shutdown(sc68);
        sc68 = NULL;
        return 0;
    }

    // 加载
    if (api68_load_mem(sc68, (const void*)data, len)) {
        api68_shutdown(sc68);
        sc68 = NULL;
        return 0;
    }

    // 获取时长
    api68_music_info_t info;
    if (!api68_music_info(sc68, &info, -1, 0)) {
        duration_ms = info.time_ms;
    }
    if (duration_ms <= 0) duration_ms = 120000; // 默认 2 分钟

    // 默认第一轨
    api68_play(sc68, 0);

    return 1;
}

static double impl_get_duration(void)
{
    return duration_ms / 1000.0;
}

static int impl_get_sample_rate(void)
{
    return sample_rate;
}

static int impl_get_channels(void)
{
    return 2; // sc68 输出立体声
}

static int impl_render(float *out, int frames)
{
    if (!sc68) return 0;

    int needed = frames; // sc68 每个 sample 是 32-bit packed stereo
    if (needed > buffer_samples) {
        int *nb = (int *)realloc(pcm_buffer, (size_t)needed * sizeof(int));
        if (!nb) return 0;
        pcm_buffer = nb;
        buffer_samples = needed;
    }

    int total = 0;
    while (total < frames) {
        int remaining = frames - total;
        int to_process = (remaining > buffer_samples) ? buffer_samples : remaining;

        int status = api68_process(sc68, pcm_buffer, to_process);
        if (status & API68_END) break;
        if (status == API68_MIX_ERROR) break;

        // sc68 packed stereo: 每个 int32 包含 left(16bit) + right(16bit)
        int n = (to_process > remaining) ? remaining : to_process;
        for (int i = 0; i < n; i++) {
            int v = pcm_buffer[i];
            out[(total + i) * 2 + 0] = (float)(int16_t)(v & 0xFFFF) / 32768.0f;
            out[(total + i) * 2 + 1] = (float)(int16_t)(v >> 16) / 32768.0f;
        }
        total += n;
    }

    return total;
}

static void impl_destroy(void)
{
    if (sc68) {
        api68_stop(sc68);
        api68_shutdown(sc68);
        sc68 = NULL;
    }
    free(pcm_buffer);
    pcm_buffer = NULL;
    buffer_samples = 0;
    duration_ms = 0;
}

// ── 导出 Decoder 实例 ──
const Decoder decoder_sc68 = {
    "sc68",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy
};
