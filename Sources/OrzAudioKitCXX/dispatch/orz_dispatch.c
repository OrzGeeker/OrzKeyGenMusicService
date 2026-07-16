#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#else
#define EMSCRIPTEN_KEEPALIVE
#endif
#include <string.h>
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

// ── 当前活跃解码器 ──

static const Decoder *active = NULL;

// 为 adplug 等需要格式扩展名的解码器传递当前格式名
const char *orz_current_format = NULL;

// 外部注册函数（在 audio_engine.c 中定义）
extern void register_all(void);

// ── 统一入口 ──

EMSCRIPTEN_KEEPALIVE
int orz_load(const char *format, const unsigned char *data, int len) {
    // 确保解码器已注册
    register_all();
    // 如果已有活跃解码器，先销毁
    if (active) {
        active->destroy();
        active = NULL;
    }
    const Decoder *dec = find_decoder(format);
    if (!dec) return 0;
    // 设当前格式名，供 adplug 等解码器获取文件扩展名
    orz_current_format = format;
    if (!dec->load(data, len)) return 0;
    active = dec;
    return 1;
}

EMSCRIPTEN_KEEPALIVE
double orz_get_duration() {
    return active ? active->get_duration() : 0.0;
}

EMSCRIPTEN_KEEPALIVE
int orz_get_sample_rate() {
    return active ? active->get_sample_rate() : 0;
}

EMSCRIPTEN_KEEPALIVE
int orz_get_channels() {
    return active ? active->get_channels() : 0;
}

EMSCRIPTEN_KEEPALIVE
int orz_render(float *out, int frames) {
    return active ? active->render(out, frames) : 0;
}

EMSCRIPTEN_KEEPALIVE
void orz_destroy() {
    if (active) {
        active->destroy();
        active = NULL;
    }
}

EMSCRIPTEN_KEEPALIVE
int orz_can_decode(const char *format) {
    return find_decoder(format) != NULL;
}
