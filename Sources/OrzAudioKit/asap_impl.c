#include <asap.h>
#include <stdlib.h>
#include <string.h>
#include "audio_engine.h"

// ── 单例状态 ──
static ASAP *asap = NULL;
static short *render_buf = NULL;
static int render_buf_size = 0;
static int total_duration_ms = 0;
#define ASAP_SAMPLE_RATE 44100

// ── Decoder 接口实现 ──

static int impl_load(const unsigned char *data, int len) {
    if (asap) { ASAP_Delete(asap); asap = NULL; }
    free(render_buf); render_buf = NULL;
    render_buf_size = 0;
    total_duration_ms = 0;

    asap = ASAP_New();
    if (!asap) return 0;

    ASAP_SetSampleRate(asap, ASAP_SAMPLE_RATE);
    ASAP_DetectSilence(asap, 5); // 5秒静音自动停止

    // ASAP_Load 参数: (self, filename, module, moduleLen)
    if (!ASAP_Load(asap, "song.sap", (const unsigned char*)data, len)) {
        ASAP_Delete(asap); asap = NULL;
        return 0;
    }

    // 获取时长
    const ASAPInfo *info = ASAP_GetInfo(asap);
    if (info) {
        total_duration_ms = ASAPInfo_GetDuration(info, 0);
    }
    if (total_duration_ms <= 0) total_duration_ms = 120000; // 默认2分钟

    // 开始播放
    if (!ASAP_PlaySong(asap, 0, total_duration_ms)) {
        ASAP_Delete(asap); asap = NULL;
        return 0;
    }

    return 1;
}

static double impl_get_duration() {
    if (!asap) return 0;
    return total_duration_ms / 1000.0;
}

static int impl_get_sample_rate() {
    return ASAP_SAMPLE_RATE;
}

static int impl_get_channels() {
    return 2; // ASAP 默认输出立体声（POKEY 双声道）
}

static int impl_render(float *out, int frames) {
    if (!asap) return 0;

    int byte_count = frames * 2 * sizeof(short); // 立体声 16-bit
    if (!render_buf || byte_count > render_buf_size) {
        short *nb = (short *)realloc(render_buf, (size_t)byte_count);
        if (!nb) return 0;
        render_buf = nb;
        render_buf_size = byte_count;
    }

    int generated = ASAP_Generate(asap, (unsigned char*)render_buf, byte_count,
                                   ASAPSampleFormat_S16_L_E);
    int samples = generated / sizeof(short); // 实际生成的样本数

    // short → float 转换（立体声交错）
    int rendered_frames = samples / 2;
    for (int i = 0; i < rendered_frames * 2 && i < samples; i++) {
        out[i] = render_buf[i] / 32768.0f;
    }
    return rendered_frames;
}

static void impl_destroy() {
    if (asap) { ASAP_Delete(asap); asap = NULL; }
    free(render_buf); render_buf = NULL;
    render_buf_size = 0;
    total_duration_ms = 0;
}

// ── 导出 Decoder 实例 ──
const Decoder decoder_asap = {
    "asap",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy
};
