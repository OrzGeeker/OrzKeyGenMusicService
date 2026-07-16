/**
 * midi_file.h — 极简 MIDI 文件解析器
 *
 * 解析标准 MIDI 文件（SMF Format 0/1）为平铺事件列表。
 * 纯 C，零外部依赖。
 */
#ifndef MIDI_FILE_H
#define MIDI_FILE_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MIDI_EV_NOTE_ON     0
#define MIDI_EV_NOTE_OFF    1
#define MIDI_EV_PROGRAM     2
#define MIDI_EV_TEMPO       3
#define MIDI_EV_END         4

typedef struct {
    double  tick;        // 事件发生的绝对刻数
    int     type;        // MIDI_EV_*
    int     channel;     // MIDI 通道 (0-15)
    int     note;        // 音符编号 (0-127)
    int     velocity;    // 力度 (0-127)
    int     program;     // 音色号 (仅 PROGRAM 事件)
    int     tempo;       // us/quarter (仅 TEMPO 事件)
} MidiEvent;

typedef struct {
    MidiEvent *events;
    int   count;
    int   capacity;
    int   ticks_per_quarter;
} MidiFile;

// ── 内部工具 ──

static inline int midi_read_vlq(const unsigned char *d, int *p) {
    int v = 0;
    unsigned char b;
    do { b = d[(*p)++]; v = (v << 7) | (b & 0x7F); } while (b & 0x80);
    return v;
}
static inline uint32_t midi_read32(const unsigned char *p) {
    return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];
}
static inline uint16_t midi_read16(const unsigned char *p) {
    return (uint16_t)((p[0]<<8)|p[1]);
}

static int midi_add_event(MidiFile *mf, double tick, int type,
                           int ch, int n, int v, int pg, int tempo) {
    if (mf->count >= mf->capacity) {
        mf->capacity = mf->capacity ? mf->capacity * 2 : 1024;
        MidiEvent *ne = (MidiEvent*)realloc(mf->events, mf->capacity * sizeof(MidiEvent));
        if (!ne) return 0;
        mf->events = ne;
    }
    MidiEvent *e = &mf->events[mf->count++];
    e->tick = tick; e->type = type; e->channel = ch;
    e->note = n; e->velocity = v; e->program = pg; e->tempo = tempo;
    return 1;
}

// ── 解析 MIDI 文件 ──

static inline int midi_load(MidiFile *mf, const unsigned char *data, int len) {
    memset(mf, 0, sizeof(*mf));
    if (len < 14 || memcmp(data, "MThd", 4)) return 0;

    int p = 8;
    int fmt = midi_read16(data + p); p += 2;
    int tracks = midi_read16(data + p); p += 2;
    mf->ticks_per_quarter = midi_read16(data + p); p += 2;
    if (mf->ticks_per_quarter <= 0) return 0;

    mf->capacity = 1024;
    mf->events = (MidiEvent*)malloc(mf->capacity * sizeof(MidiEvent));
    if (!mf->events) return 0;

    while (p < len) {
        if (p + 8 > len) break;
        if (memcmp(data + p, "MTrk", 4)) { p++; continue; }

        int trk_len = (int)midi_read32(data + p + 4);
        p += 8;
        int end = p + trk_len;
        if (end > len) end = len;

        double abs_tick = 0;
        int last_st = 0;

        while (p < end) {
            double dt = (double)midi_read_vlq(data, &p);
            abs_tick += dt;

            if (p >= end) break;
            int st = data[p];
            if (st & 0x80) { last_st = st; p++; }
            else { st = last_st; }

            if (st == 0xFF) {
                // Meta 事件
                int mt = data[p++];
                int ml = midi_read_vlq(data, &p);
                if (p + ml > end) ml = end - p;
                if (mt == 0x51 && ml >= 3) {
                    int tempo = ((int)data[p]<<16)|((int)data[p+1]<<8)|data[p+2];
                    midi_add_event(mf, abs_tick, MIDI_EV_TEMPO, 0,0,0,0, tempo);
                }
                p += ml;
                if (mt == 0x2F) break; // End of Track
            } else if (st >= 0x80 && st < 0xF0) {
                int ch = st & 0x0F;
                int type = st & 0xF0;
                int n = data[p++];
                int v = 0;
                if (type != 0xC0 && type != 0xD0) v = data[p++];

                if (type == 0x90 && v > 0) {
                    midi_add_event(mf, abs_tick, MIDI_EV_NOTE_ON, ch, n, v, 0, 0);
                } else if (type == 0x80 || (type == 0x90 && v == 0)) {
                    midi_add_event(mf, abs_tick, MIDI_EV_NOTE_OFF, ch, n, v, 0, 0);
                } else if (type == 0xC0) {
                    midi_add_event(mf, abs_tick, MIDI_EV_PROGRAM, ch, n, 0, n, 0);
                }
            } else {
                // SysEx
                if (st == 0xF0 || st == 0xF7) {
                    int sl = midi_read_vlq(data, &p);
                    p += sl;
                } else { p++; }
            }
        }
        p = end;
    }

    if (mf->count == 0) { free(mf->events); mf->events = NULL; return 0; }
    return 1;
}

static inline void midi_free(MidiFile *mf) {
    free(mf->events);
    memset(mf, 0, sizeof(*mf));
}

#ifdef __cplusplus
}
#endif

#endif /* MIDI_FILE_H */
