/**
 * uade_native_ahx.c — AHX 原生解码器
 *
 * 使用 ahx2play 库（8bitbubsy C 移植版）直接解码 AHX 格式。
 */
#include <stdlib.h>
#include <string.h>
#include "audio_engine.h"
#include "replayer.h"

// ahx2play forward declarations (not in replayer.h)
bool ahxInitWaves(void);
void ahxFreeWaves(void);

static int ahx_play_started = 0;
static int16_t *render_buf = NULL;
static int render_buf_size = 0;

static void impl_destroy(void);

static int impl_load(const unsigned char *data, int len) {
    impl_destroy();
    ahxInitWaves();
    if (!ahxLoadFromRAM(data)) return 0;
    if (!ahxInit(44100, 4096, 256, 20)) { ahxFree(); return 0; }
    return 1;
}

static double impl_get_duration(void) { return 120.0; }
static int impl_get_sample_rate(void) { return 44100; }
static int impl_get_channels(void) { return 2; }

static int impl_render(float *out, int frames) {
    if (!ahx_play_started) { ahxPlay(0); ahx_play_started = 1; }
    int needed = frames * 2;
    if (needed > render_buf_size) {
        int16_t *nb = (int16_t *)realloc(render_buf, (size_t)needed * sizeof(int16_t));
        if (!nb) return 0;
        render_buf = nb; render_buf_size = needed;
    }
    tickReplayer();
    paulaOutputSamples(render_buf, frames);
    for (int i = 0; i < frames * 2; i++) out[i] = render_buf[i] / 32768.0f;
    return frames;
}

static void impl_destroy(void) {
    ahxStop(); ahxClose(); ahxFree();
    ahx_play_started = 0;
    free(render_buf); render_buf = NULL; render_buf_size = 0;
}

const Decoder decoder_uade_ahx = {
    "ahx2play", impl_load, impl_get_duration,
    impl_get_sample_rate, impl_get_channels,
    impl_render, impl_destroy
};
