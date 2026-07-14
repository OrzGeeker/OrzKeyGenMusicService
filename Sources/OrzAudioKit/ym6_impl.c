/**
 * ym6_impl.c — YM6 (Atari ST YM2149) decoder for WASM
 *
 * YM6 format: 16× YM2149 register bytes per frame at 50fps
 * Contains built-in YM2149 (AY-3-8910 clone) emulation.
 *
 * YM register layout:
 *  R0,R1   Channel A tone period  (12-bit)
 *  R2,R3   Channel B tone period
 *  R4,R5   Channel C tone period
 *  R6      Noise period           (5-bit)
 *  R7      Mixer control
 *  R8-R10  Channel A/B/C volume
 *  R11,R12 Envelope period        (16-bit)
 *  R13     Envelope shape         (4-bit)
 */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "audio_engine.h"

// ── YM2149 emulator ──
#define YM_FPS 50

typedef struct {
    // Registers
    uint8_t regs[16];

    // Tone generators (3 channels)
    uint32_t tone_period[3];
    uint32_t tone_counter[3];
    int      tone_level[3];

    // Noise generator
    uint32_t noise_period;
    uint32_t noise_counter;
    uint32_t noise_lfsr;

    // Envelope generator
    uint32_t env_period;
    uint32_t env_counter;
    int      env_phase;       // 0-31
    int      env_direction;   // +1 or -1
    int      env_continue : 1;
    int      env_attack   : 1;
    int      env_alternate : 1;
    int      env_hold     : 1;

    // Frame data (YM6 register dumps)
    const uint8_t *frame_data;   // pointer to frame data in original buffer
    int   total_frames;
    int   current_frame;
    double frame_remainder;      // fractional sample accumulation
    int   sample_rate;
} ym6_t;

static ym6_t *ym = NULL;

// ── Reset emulator ──
static void ym6_reset(ym6_t *y) {
    memset(y, 0, sizeof(ym6_t));
    for (int i = 0; i < 3; i++) {
        y->tone_level[i] = 1;
        y->tone_period[i] = 1;
    }
    y->noise_period = 1;
    y->noise_lfsr = 1;
    y->env_period = 1;
    y->env_direction = -1;
    y->sample_rate = 44100;
}

// ── Write YM register ──
static void ym6_write_reg(ym6_t *y, int r, uint8_t v) {
    if (r < 0 || r > 15) return;
    y->regs[r] = v;
    switch (r) {
    case 0:  y->tone_period[0] = (y->tone_period[0] & 0xF00) | v; break;
    case 1:  y->tone_period[0] = (y->tone_period[0] & 0x0FF) | ((v & 0x0F) << 8); if (!y->tone_period[0]) y->tone_period[0] = 1; break;
    case 2:  y->tone_period[1] = (y->tone_period[1] & 0xF00) | v; break;
    case 3:  y->tone_period[1] = (y->tone_period[1] & 0x0FF) | ((v & 0x0F) << 8); if (!y->tone_period[1]) y->tone_period[1] = 1; break;
    case 4:  y->tone_period[2] = (y->tone_period[2] & 0xF00) | v; break;
    case 5:  y->tone_period[2] = (y->tone_period[2] & 0x0FF) | ((v & 0x0F) << 8); if (!y->tone_period[2]) y->tone_period[2] = 1; break;
    case 6:  y->noise_period = (v & 0x1F); if (!y->noise_period) y->noise_period = 1; break;
    case 11: y->env_period = (y->env_period & 0xFF00) | v; break;
    case 12: y->env_period = (y->env_period & 0x00FF) | (v << 8); if (!y->env_period) y->env_period = 1; break;
    case 13:
        y->env_continue = (v >> 3) & 1;
        y->env_attack   = (v >> 2) & 1;
        y->env_alternate= (v >> 1) & 1;
        y->env_hold     = (v >> 0) & 1;
        y->env_phase    = y->env_attack ? 0 : 31;
        y->env_direction = y->env_attack ? 1 : -1;
        y->env_counter  = 0;
        break;
    }
}

// ── Write all 16 registers from a frame ──
static void ym6_write_frame(ym6_t *y, const uint8_t *frame) {
    for (int r = 0; r < 16; r++) {
        if (frame[r] != y->regs[r]) {
            ym6_write_reg(y, r, frame[r]);
        }
    }
}

// ── Parse YM3/4/5/6 header ──
// Returns duration in seconds, or 0 on failure.
static double ym6_parse_header(const uint8_t *data, int len,
                                int *out_total_frames, int *out_frame_offset) {
    if (len < 4) return 0;
    const uint8_t m0 = data[0], m1 = data[1], m2 = data[2], m3 = data[3];
    if (m0 != 'Y' || m1 != 'M') return 0;
    if (m2 < '3' || m2 > '6') return 0;  // Only YM3-6
    if (m3 != '!' && m3 != ' ') return 0;
    if (len < 38) return 0;

    // Big-endian fields at fixed offsets
    int total_frames = (data[20] << 24) | (data[21] << 16) | (data[22] << 8) | data[23];
    if (total_frames <= 0) return 0;

    int fps = (data[28] << 8) | data[29];
    if (fps <= 0) fps = 50;

    // Header size and extra data
    int header_size = 4 + 8 + 8 + 4 + 4 + 2 + 4; // magic+name+author+frames+attrs+fps+loop
    int extra_size = 0;
    if (m2 >= '5') {
        if (len < 38) return 0;
        extra_size = (data[34] << 24) | (data[35] << 16) | (data[36] << 8) | data[37];
        header_size = 38;  // YM5/6 has 4-byte extra size at offset 34
    } else {
        if (len < 34) return 0;
        extra_size = (data[30] << 24) | (data[31] << 16) | (data[32] << 8) | data[33];
        header_size = 34;  // YM3/4 has extra size at offset 30
    }
    if (extra_size > len - header_size) return 0;

    int frame_offset = header_size + extra_size;
    int expected = frame_offset + total_frames * 16;
    if (len < expected) return 0;

    *out_total_frames = total_frames;
    *out_frame_offset = frame_offset;
    return (double)total_frames / fps;
}

// ── Render audio ──
// Processes YM6 frames and produces interleaved float PCM
static int ym6_render(ym6_t *y, float *out, int frames) {
    if (!y || !y->frame_data) return 0;

    // Calculate how many samples per frame at this sample rate
    double samples_per_frame = (double)y->sample_rate / YM_FPS;
    int rendered = 0;

    while (rendered < frames) {
        // If we need to advance to the next frame
        if (y->frame_remainder < 1.0 && y->current_frame < y->total_frames) {
            // Write the next frame's register values
            const uint8_t *frame = y->frame_data + y->current_frame * 16;
            ym6_write_frame(y, frame);
            y->current_frame++;
            y->frame_remainder += samples_per_frame;
        }

        if (y->current_frame >= y->total_frames && y->frame_remainder < 1.0) {
            break; // No more data
        }

        // How many samples to render based on current frame
        int todo = frames - rendered;
        int chunk = (int)y->frame_remainder;
        if (chunk > todo) chunk = todo;

        if (chunk <= 0) {
            // Shouldn't happen, but safety
            break;
        }

        // Render chunk samples with current register state
        for (int s = 0; s < chunk; s++, rendered++) {
            // Advance tone generators
            for (int ch = 0; ch < 3; ch++) {
                y->tone_counter[ch]++;
                if (y->tone_counter[ch] >= y->tone_period[ch]) {
                    y->tone_counter[ch] = 0;
                    y->tone_level[ch] = !y->tone_level[ch];
                }
            }

            // Advance noise generator (17-bit LFSR)
            y->noise_counter++;
            if (y->noise_counter >= y->noise_period) {
                y->noise_counter = 0;
                int fb = ((y->noise_lfsr & 1) ^ ((y->noise_lfsr >> 3) & 1)) ^ 1;
                y->noise_lfsr = (y->noise_lfsr >> 1) | (fb << 16);
            }

            // Advance envelope
            y->env_counter++;
            if (y->env_counter >= y->env_period) {
                y->env_counter = 0;
                int old_phase = y->env_phase;
                (void)old_phase;
                y->env_phase += y->env_direction;
                if (y->env_phase < 0 || y->env_phase > 31) {
                    if (y->env_phase < 0) y->env_phase = 0;
                    if (y->env_phase > 31) y->env_phase = 31;
                    if (!y->env_continue) {
                        y->env_direction = 0;
                    } else if (y->env_alternate) {
                        y->env_direction = -y->env_direction;
                        y->env_phase += y->env_direction;
                    } else {
                        y->env_phase = y->env_attack ? 0 : 31;
                    }
                    if (y->env_hold) y->env_direction = 0;
                }
            }

            // Mix 3 channels
            int mixer = y->regs[7];
            double left = 0, right = 0;

            for (int ch = 0; ch < 3; ch++) {
                int vol_byte = y->regs[8 + ch];
                int use_env = (vol_byte >> 4) & 1;
                int fixed_vol = vol_byte & 0x0F;
                double ampl;
                if (use_env)
                    ampl = (y->env_phase & 0x1F) / 31.0;
                else
                    ampl = fixed_vol / 15.0;

                int tone_on = !((mixer >> ch) & 1);
                int noise_on = !((mixer >> (ch + 3)) & 1);

                double val = 0.0;
                if (tone_on) val += y->tone_level[ch] ? 1.0 : -1.0;
                if (noise_on) val += (y->noise_lfsr & 1) ? 1.0 : -1.0;
                if (tone_on && noise_on) val *= 0.5;

                val *= ampl * 0.4;  // master gain

                // Pan: ch0→L, ch1→center, ch2→R
                if (ch == 0)      { left += val; }
                else if (ch == 1) { left += val * 0.7; right += val * 0.7; }
                else              { right += val; }
            }

            out[rendered * 2 + 0] = (float)left;
            out[rendered * 2 + 1] = (float)right;
        }

        y->frame_remainder -= chunk;
    }

    return rendered;
}

// ── Decoder interface ──
static int impl_load(const unsigned char *data, int len) {
    if (ym) { free(ym); ym = NULL; }

    int total_frames = 0, frame_offset = 0;
    double duration = ym6_parse_header(data, len, &total_frames, &frame_offset);
    if (duration <= 0 || total_frames <= 0) return 0;

    ym = (ym6_t*)calloc(1, sizeof(ym6_t));
    if (!ym) return 0;

    ym6_reset(ym);
    ym->frame_data = data + frame_offset;
    ym->total_frames = total_frames;
    ym->current_frame = 0;
    ym->frame_remainder = 0;
    ym->sample_rate = 44100;

    // Apply the first frame immediately
    if (total_frames > 0) {
        ym6_write_frame(ym, ym->frame_data);
        ym->current_frame = 1;
        ym->frame_remainder = (double)ym->sample_rate / YM_FPS;
    } else {
        free(ym); ym = NULL;
        return 0;
    }

    return 1;
}

static double impl_get_duration(void) { return ym ? (double)ym->total_frames / YM_FPS : 0; }
static int    impl_get_sample_rate(void) { return 44100; }
static int    impl_get_channels(void) { return 2; }

static int impl_render(float *out, int frames) {
    return ym ? ym6_render(ym, out, frames) : 0;
}

static void impl_destroy(void) {
    if (ym) { free(ym); ym = NULL; }
}

// ── Export decoder ──
const Decoder decoder_ym6 = {
    "ym6",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy
};
