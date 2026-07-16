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
#ifndef EMSCRIPTEN
#define EMSCRIPTEN 1  // 暴露 api68_override_max_playtime 等 EMSCRIPTEN 专用函数
#endif
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
static int sc68_ended = 0;          // 歌曲结束后标记，后续 render 返回 0

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
    sc68_ended = 0;

    // 注册 inline replay modules
    register_players();

    // 初始化 API
    memset(&init68, 0, sizeof(init68));
    init68.alloc = sc68_alloc;
    init68.free = sc68_free;
    init68.sampling_rate = sample_rate;

    sc68 = api68_init(&init68);
    if (!sc68) return 0;

    // 验证并加载（仅 sc68 原生格式）
    if (api68_verify_mem((const void*)data, len) < 0
        || api68_load_mem(sc68, (const void*)data, len)) {
        api68_shutdown(sc68);
        sc68 = NULL;
        return 0;
    }

    // 限制最大播放时长（必须在 play 之前设置）
    api68_override_max_playtime(30000);

    // 默认第一轨（关联播放器，必须在 music_info 前启动）
    api68_play(sc68, 0);

    // 获取时长 — 大多数 sc68 keygen 文件没有内嵌时长信息
    // 注意：WASM 中 68K 模拟速度较慢（每帧 160K cycles），限制为 30 秒避免卡死
    api68_music_info_t info;
    for (int try_track = 0; try_track >= -1 && duration_ms <= 0; try_track--) {
        memset(&info, 0, sizeof(info));
        int ret = api68_music_info(sc68, &info, try_track, 0);
        if (ret == 0 && info.time_ms > 0 && info.time_ms < 3600000) {
            duration_ms = info.time_ms;
        }
    }
    if (duration_ms <= 0) duration_ms = 30000; // WASM 默认 30 秒

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

    // 歌曲已结束（上次调用已返回 API68_END），返回 0 让 JS 流式循环退出
    if (sc68_ended) return 0;

    // 使用 static 内部缓冲区 + 固定 512 帧（与 emscripten adapter 一致）
    // api68_process 内部循环直到填满请求帧数或遇到结束才返回
    static int pcm[512];
    int to_process = 512;
    if (frames < to_process) to_process = frames;

    int status = api68_process(sc68, pcm, to_process);

    if (status & API68_END) {
        int real_ms = 0;
        int seek_pos = api68_seek(sc68, -1);
        if (seek_pos > 0) real_ms = seek_pos;
        if (real_ms <= 0) real_ms = (int)((unsigned long long)to_process * 1000 / sample_rate);
        if (real_ms > 0 && real_ms < duration_ms) duration_ms = real_ms;
        // 标记已结束，下次 render 返回 0 让 JS 流式循环退出
        sc68_ended = 1;
    }
    if (status == API68_MIX_ERROR) return 0;

    for (int i = 0; i < to_process; i++) {
        int v = pcm[i];
        out[i * 2 + 0] = (float)(int16_t)(v & 0xFFFF) / 32768.0f;
        out[i * 2 + 1] = (float)(int16_t)(v >> 16) / 32768.0f;
    }
    return to_process;
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
    sc68_ended = 0;
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
