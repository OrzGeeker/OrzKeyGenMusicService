#include <gme/gme.h>
#include <stdlib.h>
#include <string.h>
#include "audio_engine.h"

// C++ 异常安全包装（在 cxx_helpers.cpp 中实现）
extern const char* safe_gme_open_data(const unsigned char*, int, Music_Emu**, int);
extern const char* safe_gme_start_track(Music_Emu*, int);
extern const char* safe_gme_track_info(Music_Emu*, gme_info_t**, int);
extern void        safe_gme_free_info(gme_info_t*);
extern const char* safe_gme_play(Music_Emu*, int, short*);
extern void        safe_gme_delete(Music_Emu*);

// ── 单例状态 ──
static Music_Emu *emu = NULL;
static short *render_buf = NULL;
static int render_buf_size = 0;
#define GME_SAMPLE_RATE 44100

// ── Decoder 接口实现 ──

static int impl_load(const unsigned char *data, int len) {
    if (emu) { safe_gme_delete(emu); emu = NULL; }
    free(render_buf); render_buf = NULL;
    render_buf_size = 0;

    // gme_open_data 自动检测格式（nsf, spc, gbs 等）
    const char* err = safe_gme_open_data(data, len, &emu, GME_SAMPLE_RATE);
    if (err) return 0;

    // 从第一轨开始播放
    err = safe_gme_start_track(emu, 0);
    if (err) { safe_gme_delete(emu); emu = NULL; return 0; }

    return 1;
}

static double impl_get_duration() {
    if (!emu) return 0;
    gme_info_t *info = NULL;
    if (safe_gme_track_info(emu, &info, 0)) return 0;
    double secs = 0;
    if (info->length > 0) {
        secs = info->length / 1000.0;
    } else if (info->play_length > 0) {
        secs = info->play_length / 1000.0;
    } else {
        // 格式可能没有长度信息（如 NSF），默认 2 分钟
        secs = 120.0;
    }
    safe_gme_free_info(info);
    return secs;
}

static int impl_get_sample_rate() {
    return GME_SAMPLE_RATE;
}

static int impl_get_channels() {
    return 2; // gme 始终输出立体声
}

static int impl_render(float *out, int frames) {
    if (!emu) return 0;

    int sample_count = frames * 2; // 立体声
    if (!render_buf || sample_count > render_buf_size) {
        short *nb = (short *)realloc(render_buf, (size_t)sample_count * sizeof(short));
        if (!nb) return 0;
        render_buf = nb;
        render_buf_size = sample_count;
    }

    const char* err = safe_gme_play(emu, sample_count, render_buf);
    if (err) return 0;

    // int16 → float32 转换
    for (int i = 0; i < frames * 2; i++) {
        out[i] = render_buf[i] / 32768.0f;
    }
    return frames;
}

static void impl_destroy() {
    if (emu) { safe_gme_delete(emu); emu = NULL; }
    free(render_buf); render_buf = NULL;
    render_buf_size = 0;
}

// ── 导出 Decoder 实例 ──
const Decoder decoder_gme = {
    "game-music-emu",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy
};
