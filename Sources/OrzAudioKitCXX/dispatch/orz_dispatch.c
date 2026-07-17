#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#else
#define EMSCRIPTEN_KEEPALIVE
#endif
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include "audio_engine.h"

// ── 解码器注册表 ──

typedef struct {
    const char *extensions;  // 逗号分隔的格式列表
    const Decoder *decoder;
} FormatEntry;

#define MAX_DECODERS 16
static FormatEntry format_entries[MAX_DECODERS];
static int entry_count = 0;

void orz_register_decoder(const char *extensions, const Decoder *decoder) {
    if (entry_count >= MAX_DECODERS) return;
    format_entries[entry_count].extensions = extensions;
    format_entries[entry_count].decoder = decoder;
    entry_count++;
}

static const Decoder *find_decoder(const char *format) {
    if (!format) return NULL;
    for (int i = 0; i < entry_count; i++) {
        const char *ext = format_entries[i].extensions;
        while (ext && *ext) {
            // 跳过逗号
            while (*ext == ' ' || *ext == ',') ext++;
            if (!*ext) break;
            // 比较扩展名
            const char *start = ext;
            while (*ext && *ext != ',') ext++;
            int len = (int)(ext - start);
            if ((int)strlen(format) == len &&
                strncmp(format, start, len) == 0) {
                return format_entries[i].decoder;
            }
        }
    }
    return NULL;
}

static int has_complete_context_api(const Decoder *decoder) {
    return decoder->create && decoder->context_get_duration &&
           decoder->context_get_sample_rate && decoder->context_get_channels &&
           decoder->context_render && decoder->context_destroy;
}

// ── 当前活跃解码器 ──

struct OrzDecoderHandle {
    const Decoder *decoder;
    void *context;
    int legacy;
};

static OrzDecoderHandle *active = NULL;
static const Decoder *legacy_owner = NULL;

// 为 adplug 等需要格式扩展名的解码器传递当前格式名
const char *orz_current_format = NULL;

// 外部注册函数（在 audio_engine.c 中定义）
extern void register_all(void);

// ── 统一入口 ──

EMSCRIPTEN_KEEPALIVE
int orz_load(const char *format, const unsigned char *data, int len) {
    orz_destroy();
    active = orz_decoder_create(format, data, len);
    return active != NULL;
}

EMSCRIPTEN_KEEPALIVE
double orz_get_duration() {
    return orz_decoder_get_duration(active);
}

EMSCRIPTEN_KEEPALIVE
int orz_get_sample_rate() {
    return orz_decoder_get_sample_rate(active);
}

EMSCRIPTEN_KEEPALIVE
int orz_get_channels() {
    return orz_decoder_get_channels(active);
}

EMSCRIPTEN_KEEPALIVE
int orz_render(float *out, int frames) {
    return orz_decoder_render(active, out, frames);
}

EMSCRIPTEN_KEEPALIVE
void orz_destroy() {
    orz_decoder_destroy(active);
    active = NULL;
}

EMSCRIPTEN_KEEPALIVE
int orz_can_decode(const char *format) {
    register_all();
    return find_decoder(format) != NULL;
}

EMSCRIPTEN_KEEPALIVE
OrzDecoderHandle *orz_decoder_create(const char *format, const unsigned char *data, int len) {
    register_all();
    // Bound untrusted inputs before any third-party parser sees them. The
    // public ABI uses signed int lengths, and no supported music format needs
    // hundreds of MiB of in-memory module data.
    if (!format || !data || len < 32 || len > 512 * 1024 * 1024) return NULL;
    const Decoder *dec = find_decoder(format);
    if (!dec) return NULL;

    OrzDecoderHandle *handle = (OrzDecoderHandle *)calloc(1, sizeof(*handle));
    if (!handle) return NULL;
    handle->decoder = dec;

    if (dec->create) {
        if (!has_complete_context_api(dec)) { free(handle); return NULL; }
        handle->context = dec->create(format, data, len);
        if (!handle->context) { free(handle); return NULL; }
        return handle;
    }

    // Singleton implementations cannot safely back two live handles.
    if (legacy_owner || !dec->load) { free(handle); return NULL; }
    orz_current_format = format;
    if (!dec->load(data, len)) { free(handle); return NULL; }
    legacy_owner = dec;
    handle->legacy = 1;
    return handle;
}

EMSCRIPTEN_KEEPALIVE
double orz_decoder_get_duration(const OrzDecoderHandle *handle) {
    if (!handle) return 0.0;
    return handle->context ? handle->decoder->context_get_duration(handle->context)
                           : handle->decoder->get_duration();
}

EMSCRIPTEN_KEEPALIVE
int orz_decoder_get_sample_rate(const OrzDecoderHandle *handle) {
    if (!handle) return 0;
    return handle->context ? handle->decoder->context_get_sample_rate(handle->context)
                           : handle->decoder->get_sample_rate();
}

EMSCRIPTEN_KEEPALIVE
int orz_decoder_get_channels(const OrzDecoderHandle *handle) {
    if (!handle) return 0;
    return handle->context ? handle->decoder->context_get_channels(handle->context)
                           : handle->decoder->get_channels();
}

EMSCRIPTEN_KEEPALIVE
int orz_decoder_render(OrzDecoderHandle *handle, float *out, int frames) {
    // Every decoder outputs at most stereo float32. Prevent frames*2 and byte
    // count overflow in backend scratch-buffer calculations.
    if (!handle || !out || frames <= 0 || frames > INT_MAX / 2) return 0;
    return handle->context ? handle->decoder->context_render(handle->context, out, frames)
                           : handle->decoder->render(out, frames);
}

EMSCRIPTEN_KEEPALIVE
void orz_decoder_destroy(OrzDecoderHandle *handle) {
    if (!handle) return;
    if (handle->context) {
        handle->decoder->context_destroy(handle->context);
    } else if (handle->legacy) {
        handle->decoder->destroy();
        if (legacy_owner == handle->decoder) legacy_owner = NULL;
    }
    free(handle);
}

EMSCRIPTEN_KEEPALIVE
int orz_decoder_get_subsong_count(const OrzDecoderHandle *handle) {
    if (!handle || !handle->context || !handle->decoder->context_get_subsong_count) return -1;
    return handle->decoder->context_get_subsong_count(handle->context);
}

EMSCRIPTEN_KEEPALIVE
int orz_decoder_select_subsong(OrzDecoderHandle *handle, int subsong) {
    if (!handle || !handle->context || !handle->decoder->context_select_subsong || subsong < 0) return -1;
    return handle->decoder->context_select_subsong(handle->context, subsong);
}

EMSCRIPTEN_KEEPALIVE
int orz_decoder_seek_ms(OrzDecoderHandle *handle, int position_ms) {
    if (!handle || !handle->context || !handle->decoder->context_seek_ms || position_ms < 0) return -1;
    return handle->decoder->context_seek_ms(handle->context, position_ms);
}
