/**
 * v2m WASM wrapper — V2M format decoder for WebAssembly
 */
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <new>
#include <stdio.h>

#define __int64 long long
#define __stdcall
#define _M_IX86 300
typedef long long int64_t;
typedef unsigned long long uint64_t;

#include "v2m/types.h"
#include "v2m/synth.h"
#include "v2m/v2mplayer.h"

typedef void (__stdcall DSIOCALLBACK)(void *parm, float *buf, unsigned long len);

// ── DirectSound stubs ──
unsigned long __stdcall dsInit(DSIOCALLBACK*,void*,void*) { return 0; }
void __stdcall dsClose() {}
signed long __stdcall dsGetCurSmp() { return 0; }
void __stdcall dsSetVolume(float) {}
void __stdcall dsTick() {}
void __stdcall dsLock() {}
void __stdcall dsUnlock() {}

// ── Decoder interface ──
#include "audio_engine.h"

static V2MPlayer *v2m_player = NULL;
static int v2m_samplerate = 44100;
static double v2m_duration = 180.0;

// Parse V2M header: [timediv(4)][maxtime(4)][gdnum(4)]...
static double v2m_parse_duration(const unsigned char *data)
{
    sU32 timediv = *(const sU32*)data;
    sU32 maxtime = *(const sU32*)(data + 4);
    if (timediv == 0) return 180.0;
    return (double)maxtime / 1000.0;
}

static int impl_load(const unsigned char *data, int len)
{
    if (v2m_player) { v2m_player->Close(); delete v2m_player; v2m_player = NULL; }
    v2m_duration = v2m_parse_duration(data);
    v2m_samplerate = 44100;
    v2m_player = new(std::nothrow) V2MPlayer();
    if (!v2m_player) return 0;
    v2m_player->Init();
    if (!v2m_player->Open(data, v2m_samplerate)) { delete v2m_player; v2m_player = NULL; return 0; }
    v2m_player->Play(0);
    return 1;
}

static double impl_get_duration() { return v2m_duration; }
static int impl_get_sample_rate() { return v2m_samplerate; }
static int impl_get_channels() { return 2; }

static int impl_render(float *out, int frames)
{
    if (!v2m_player) return 0;
    v2m_player->Render((sF32*)out, (sU32)frames, 0);
    return frames;
}

static void impl_destroy()
{
    if (v2m_player) { v2m_player->Close(); delete v2m_player; v2m_player = NULL; }
}

extern "C" const Decoder decoder_v2m = {
    "v2m-player",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy
};

