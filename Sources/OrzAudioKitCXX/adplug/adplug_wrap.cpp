/**
 * adplug_wrap.cpp — AdPlug OPL2/3 decoder C++ wrapper for WASM
 *
 * Formats: rad, d00, hsc (+ 20+ more OPL2/3 formats)
 * Uses: CEmuopl (emulated OPL2), CAdPlug factory pattern
 * File access: Write to MEMFS, then load via CProvider_Filesystem
 */
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

#include <adplug.h>
#include <emuopl.h>

// Forward declarations (defined in adplug_impl.c)
extern "C" void adplug_destroy();
extern "C" int adplug_load(const unsigned char *data, int len);
extern "C" double adplug_get_duration();
extern "C" int adplug_get_sample_rate();
extern "C" int adplug_get_channels();
extern "C" int adplug_render(float *out, int frames);
extern "C" {
#include "audio_engine.h"
}

// 由 orz_dispatch.c 设置的当前格式名（如 "hsc", "amd", "rad"）
extern const char *orz_current_format;

// ── State ──
static CEmuopl *opl = NULL;
static CPlayer *player = NULL;
static int sample_rate = 44100;
static double song_duration = 0;

// Temporary filename for MEMFS
// 扩展名根据 orz_current_format 设置（"hsc"→".hsc" 等），使 AdPlug factory
// 的扩展名匹配机制正确识别格式。程序化编译为 ".adplug" 走全 player 遍历。
static int tmp_counter = 0;
static char tmp_file_path[80] = "/tmp/adplug_song.adplug";

// ── Decoder interface ──

extern "C" int adplug_load(const unsigned char *data, int len)
{
    // Cleanup
    adplug_destroy();

    // 根据当前格式名确定 MEMFS 文件的扩展名
    const char *ext = ".adplug";
    if (orz_current_format) {
        if (strcmp(orz_current_format, "hsc") == 0) ext = ".hsc";
        else if (strcmp(orz_current_format, "amd") == 0) ext = ".amd";
        else if (strcmp(orz_current_format, "rad") == 0) ext = ".rad";
        else if (strcmp(orz_current_format, "d00") == 0) ext = ".d00";
        else if (strcmp(orz_current_format, "hsp") == 0) ext = ".hsp";
        else if (strcmp(orz_current_format, "bp") == 0) ext = ".bp";
    }

    // Write data to MEMFS with format-appropriate extension
    snprintf(tmp_file_path, sizeof(tmp_file_path), "/tmp/adplug_%d%s", ++tmp_counter, ext);
    FILE *f = fopen(tmp_file_path, "wb");
    if (!f) return 0;
    fwrite(data, 1, len, f);
    fclose(f);

    // Create OPL emulator: 44100Hz, 16-bit, stereo
    opl = new CEmuopl(sample_rate, true, true);
    if (!opl) return 0;
    opl->init();

    // Load file with AdPlug factory（通过内容检测格式，不依赖扩展名）
    player = CAdPlug::factory(tmp_file_path, opl);
    if (!player) {
        delete opl; opl = NULL;
        return 0;
    }

    // Get duration
    song_duration = player->songlength() / 1000.0;
    if (song_duration <= 0) song_duration = 120.0;

    // MEMFS 是临时的，不需要显式删除
    // 注意：在 ALLOW_MEMORY_GROWTH=1 时调用 remove() 可能导致 TextDecoder 异常
    return 1;
}

extern "C" double adplug_get_duration() { return song_duration; }
extern "C" int adplug_get_sample_rate() { return sample_rate; }
extern "C" int adplug_get_channels() { return 2; }

extern "C" int adplug_render(float *out, int frames)
{
    if (!player || !opl) return 0;

    // AdPlug render loop:
    // player->update() = advance one tick, writes OPL registers
    // emuopl->update(buf, samples) = render OPL output to buffer
    //
    // For each tick, render samples_per_tick = sample_rate / refresh_rate
    float refresh = player->getrefresh();
    int samples_per_tick = (refresh > 0) ? (int)(sample_rate / refresh) : sample_rate / 50;

    int total = 0;
    while (total < frames) {
        int remaining = frames - total;
        int chunk = (remaining < samples_per_tick) ? remaining : samples_per_tick;

        // Render OPL audio directly to output
        short mixbuf[8192];
        int mix_samples = (chunk > 4096) ? 4096 : chunk;

        if (!player->update()) break; // song ended

        opl->update(mixbuf, mix_samples);

        // short → float
        for (int i = 0; i < mix_samples * 2 && total < frames; i++) {
            out[total * 2 + i] = mixbuf[i] / 32768.0f;
        }
        total += mix_samples;
    }

    return total;
}

extern "C" void adplug_destroy()
{
    delete player; player = NULL;
    delete opl; opl = NULL;
}
