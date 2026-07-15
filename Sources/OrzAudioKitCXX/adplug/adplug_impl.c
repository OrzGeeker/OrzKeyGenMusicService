/**
 * adplug_impl.c — AdPlug OPL2/3 decoder wrapper (rad, d00, hsc)
 *
 * Uses CEmuopl OPL emulator at 44100Hz stereo.
 * Reads file data via MEMFS (write to virtual FS, then load).
 */
#include <stdlib.h>
#include <string.h>
#include "audio_engine.h"

// C++ compile guards (this file is compiled as C with emcc)
// We include the C++ headers in a separate .cpp wrapper
// This file provides the C Decoder interface

extern int adplug_load(const unsigned char *data, int len);
extern double adplug_get_duration();
extern int adplug_get_sample_rate();
extern int adplug_get_channels();
extern int adplug_render(float *out, int frames);
extern void adplug_destroy();

const Decoder decoder_adplug = {
    "adplug",
    adplug_load,
    adplug_get_duration,
    adplug_get_sample_rate,
    adplug_get_channels,
    adplug_render,
    adplug_destroy
};
