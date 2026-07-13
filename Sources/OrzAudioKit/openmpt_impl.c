#include <libopenmpt/libopenmpt.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "audio_engine.h"

// C++ 异常安全包装（在 cxx_helpers.cpp 中实现）
extern openmpt_module* safe_openmpt_create(const unsigned char* data, size_t len);
extern double safe_openmpt_duration(openmpt_module* mod);
extern size_t safe_openmpt_render(openmpt_module* mod, int rate, size_t frames,
                                  float* left, float* right);
extern void safe_openmpt_destroy(openmpt_module* mod);

// ── 单例状态 ──
static openmpt_module *mod = NULL;
static float *render_left = NULL;
static float *render_right = NULL;
static int render_buf_size = 0;

// ── Decoder 接口实现 ──

static int impl_load(const unsigned char *data, int len) {
    if (mod) {
        safe_openmpt_destroy(mod);
        mod = NULL;
    }
    free(render_left);  render_left  = NULL;
    free(render_right); render_right = NULL;
    render_buf_size = 0;

    mod = safe_openmpt_create(data, (size_t)len);
    return mod ? 1 : 0;
}

static double impl_get_duration() {
    if (!mod) return 0;
    return safe_openmpt_duration(mod);
}

static int impl_get_sample_rate() {
    return 48000;
}

static int impl_get_channels() {
    return 2;
}

static int impl_render(float *out, int frames) {
    if (!mod) return 0;

    if (!render_left || frames > render_buf_size) {
        float *nl = (float *)realloc(render_left,  (size_t)frames * sizeof(float));
        float *nr = (float *)realloc(render_right, (size_t)frames * sizeof(float));
        if (!nl || !nr) return 0;
        render_left  = nl;
        render_right = nr;
        render_buf_size = frames;
    }

    size_t rendered = safe_openmpt_render(
        mod, 48000, (size_t)frames, render_left, render_right
    );

    for (size_t i = 0; i < rendered && i < (size_t)frames; i++) {
        out[i * 2 + 0] = render_left[i];
        out[i * 2 + 1] = render_right[i];
    }
    return (int)rendered;
}

static void impl_destroy() {
    if (mod) {
        safe_openmpt_destroy(mod);
        mod = NULL;
    }
    free(render_left);  render_left  = NULL;
    free(render_right); render_right = NULL;
    render_buf_size = 0;
}

// ── 导出 Decoder 实例 ──
const Decoder decoder_openmpt = {
    "libopenmpt",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy
};
