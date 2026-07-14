/**
 * uade_wasm.c — UADE (Amiga emulator) WASM decoder wrapper
 *
 * Plays AHX and AMD Amiga music formats via the UAE Amiga emulator.
 * The UAE core (19K lines C + 2MB generated CPU tables) requires
 * dedicated porting — the full implementation will be completed as
 * a separate task.
 */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "audio_engine.h"

static int impl_load(const unsigned char *data, int len) {
    (void)data; (void)len;
    return 0;  // TODO: UAE core integration
}

static double impl_get_duration(void) { return 0; }
static int impl_get_sample_rate(void) { return 44100; }
static int impl_get_channels(void) { return 2; }
static int impl_render(float *out, int frames) { (void)out; (void)frames; return 0; }
static void impl_destroy(void) {}

const Decoder decoder_uade = {
    "uade",
    impl_load, impl_get_duration,
    impl_get_sample_rate, impl_get_channels,
    impl_render, impl_destroy
};
