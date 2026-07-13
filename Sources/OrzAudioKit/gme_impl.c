#include <gme/gme.h>
#include <stdlib.h>
#include <string.h>
#include "audio_engine.h"

// ── 单例状态 ──
static Music_Emu *emu = NULL;
static short *render_buf = NULL;
static int render_buf_size = 0;
#define GME_SAMPLE_RATE 44100

// ── Decoder 接口实现 ──

static int impl_load(const unsigned char *data, int len) {
    if (emu) { gme_delete(emu); emu = NULL; }
    free(render_buf); render_buf = NULL;
    render_buf_size = 0;

    // gme_open_data 自动检测格式（nsf, spc, gbs 等）
    gme_err_t err = gme_open_data(data, len, &emu, GME_SAMPLE_RATE);
    if (err) return 0;

    // 从第一轨开始播放
    err = gme_start_track(emu, 0);
    if (err) { gme_delete(emu); emu = NULL; return 0; }

    return 1;
}

static double impl_get_duration() {
    if (!emu) return 0;
    gme_info_t *info = NULL;
    if (gme_track_info(emu, &info, 0)) return 0;
    double secs = 0;
    if (info->length > 0) {
        secs = info->length / 1000.0;
    } else if (info->play_length > 0) {
        secs = info->play_length / 1000.0;
    } else {
        // 格式可能没有长度信息（如 NSF），默认 2 分钟
        secs = 120.0;
    }
    gme_free_info(info);
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

    gme_err_t err = gme_play(emu, sample_count, render_buf);
    if (err) return 0;

    // int16 → float32 转换
    for (int i = 0; i < frames * 2; i++) {
        out[i] = render_buf[i] / 32768.0f;
    }
    return frames;
}

static void impl_destroy() {
    if (emu) { gme_delete(emu); emu = NULL; }
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
