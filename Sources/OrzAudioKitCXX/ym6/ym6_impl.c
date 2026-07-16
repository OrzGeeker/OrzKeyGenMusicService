/**
 * ym6_impl.c — YM6 (Atari ST YM2149) decoder for WASM
 *
 * YM6 format: 16× YM2149 register bytes per frame at 50fps
 * Contains built-in YM2149 (AY-3-8910 clone) emulation.
 * Also handles LHa-compressed YM files (LH5/LH6) — no external lha needed.
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

// ── Embedded LHa/LZH decompressor (LH5/LH6) ───────────────────────────
// 零系统依赖，无需外部 lha/lhasa 命令

// Bit reader state for LZH decompression
struct lz_reader {
    const unsigned char *in;
    int in_len;
    int in_pos;
    unsigned int buf;     // bit buffer
    int bits;             // bits remaining in buffer
};

static int lz_read_byte(struct lz_reader *r, unsigned char *out) {
    if (r->in_pos >= r->in_len) return -1;
    *out = r->in[r->in_pos++];
    return 0;
}

static int lz_read_bit(struct lz_reader *r) {
    if (r->bits <= 0) {
        unsigned char b;
        if (lz_read_byte(r, &b) < 0) return -1;
        r->buf = b;
        r->bits = 8;
    }
    r->bits--;
    int bit = (r->buf >> r->bits) & 1;
    return bit;
}

static int lz_read_bits(struct lz_reader *r, int n) {
    int val = 0;
    for (int i = 0; i < n; i++) {
        int bit = lz_read_bit(r);
        if (bit < 0) return 0;
        val = (val << 1) | bit;
    }
    return val;
}

// Decode LZH match length (unary coding: count leading 1-bits)
// LH5: 0→len2, 10→3, 110→4, 1110→5, 11110→6, 111110→7, 1111110→8+5bits(range 8-39)
// LH6: same + 11111110→40+9bits(range 40-551)
static int lz_decode_length(struct lz_reader *r, int is_lh6) {
    int ones = 0;
    while (1) {
        int bit = lz_read_bit(r);
        if (bit < 0) return 2;           // fallback
        if (bit == 0) break;             // found the 0 terminator
        ones++;
        if (is_lh6 && ones >= 7) break;   // LH6: 7+ ones means extended
    }
    if (ones <= 5) {
        return ones + 2;                  // 2-7
    } else if (!is_lh6) {
        // LH5: read 5 extra bits
        return lz_read_bits(r, 5) + 8;    // 8-39
    } else {
        // LH6: check for extended
        if (ones == 6) {
            return lz_read_bits(r, 5) + 8; // 8-39
        } else {
            // ones == 7: read 9 extra bits
            return lz_read_bits(r, 9) + 40; // 40-551
        }
    }
}

// Decompress LH5/LH6 data block
// Returns: decompressed data length, or -1 on error
// *out_data receives malloc'd buffer (caller must free)
static int lz_decompress_lh(const unsigned char *in, int in_len,
                             unsigned char **out_data, int is_lh6) {
    if (in_len < 24) return -1;

    // LHa Level 0 header layout (common for YM files):
    // [2]  header_skip       (checksum + flags, skip past)
    // [5]  method            (e.g., "-lh5-")
    // [4]  packed_size       (LE 32-bit)
    // [4]  original_size     (LE 32-bit)
    // [2]  time (DOS)
    // [2]  date (DOS)
    // [1]  attribute
    // [1]  level (= 0 or 1 or 2)
    // [1]  name_length (n)
    // [n]  name
    // [2]  CRC16 (if level 0, optional for level 1/2)
    // ─── compressed data follows ───

    // Original size at offset 2+5 = 7 → actually at offset 11
    // Magic " -lh5-" starts at offset 2
    // Packed size starts at offset 7 (LE)
    // Original size starts at offset 11 (LE)
    int method_off = 2;
    int packed_off  = method_off + 5;                     // 7
    int orig_off    = packed_off + 4;                     // 11
    int time_off    = orig_off + 4;                       // 15
    int date_off    = time_off + 2;                       // 17
    int attr_off    = date_off + 2;                       // 19
    int level_off   = attr_off + 1;                       // 20
    int name_len_off = level_off + 1;                     // 21

    if (in_len <= name_len_off) return -1;
    int level = in[level_off];                             // 0, 1, or 2
    int name_len = in[name_len_off];

    // Read original size
    int orig_size = in[orig_off] | (in[orig_off+1] << 8) |
                    (in[orig_off+2] << 16) | (in[orig_off+3] << 24);
    if (orig_size <= 0 || orig_size > 4 * in_len || orig_size > 32 * 1024 * 1024) {
        return -1;
    }

    // Calculate header size
    int hdr_size = name_len_off + 1 + name_len; // up to end of name
    if (level == 0) {
        hdr_size += 2; // CRC-16 (present in level 0)
    }
    // Level 1/2 may have extended headers; for simplicity, skip forward
    // until we find the compressed data marker
    if (level >= 1 && hdr_size < in_len) {
        // Level 1: extended header blocks follow the name
        while (hdr_size < in_len - 2) {
            int ext_size = in[hdr_size] | (in[hdr_size+1] << 8);
            if (ext_size == 0) {
                hdr_size += 2;
                break;  // end of extended headers marker
            }
            hdr_size += ext_size;
        }
    }

    if (hdr_size >= in_len) {
        // Fallback: just skip past the known header fields
        hdr_size = name_len_off + 1 + name_len;
        if (level == 0) hdr_size += 2;
    }

    unsigned char *out = (unsigned char *)malloc(orig_size);
    if (!out) return -1;

    struct lz_reader r;
    r.in = in;
    r.in_len = in_len;
    r.in_pos = 0;
    r.buf = 0;
    r.bits = 0;

    r.in_pos = hdr_size;
    if (r.in_pos >= in_len) { free(out); return -1; }

    int offset_bits = is_lh6 ? 16 : 13;
    int out_pos = 0;

    while (out_pos < orig_size) {
        int flag = lz_read_bit(&r);
        if (flag < 0) break;

        if (flag == 0) {
            // Literal byte
            unsigned char c;
            if (lz_read_byte(&r, &c) < 0) break;
            out[out_pos++] = c;
        } else {
            // Match: copy from sliding window
            // LZH 流顺序：length 先于 offset
            int length = lz_decode_length(&r, is_lh6);
            int offset = lz_read_bits(&r, offset_bits) + 1;

            if (offset > out_pos) offset = out_pos; // safety
            if (length > orig_size - out_pos) length = orig_size - out_pos;

            for (int i = 0; i < length && out_pos < orig_size; i++) {
                out[out_pos] = out[out_pos - offset];
                out_pos++;
            }
        }
    }

    *out_data = out;
    return out_pos;
}

// Check if data is LHa-compressed and decompress if so.
// Returns 0 if already raw YM6, 1 if decompressed successfully, -1 on error.
// If decompressed, frees *data and replaces with new buffer.
static int ym6_decompress_lha(const unsigned char **data_ptr, int *len_ptr) {
    const unsigned char *data = *data_ptr;
    int len = *len_ptr;
    if (len < 6) return 0;

    // LHa LH5 magic: "-lh5-" at offset 2 (after header_skip[2])
    // LHa LH6 magic: "-lh6-" at offset 2
    if (data[2] == '-' && data[3] == 'l' && data[4] == 'h' &&
        (data[5] == '5' || data[5] == '6') && data[6] == '-') {
        int is_lh6 = (data[3] == '6');
        unsigned char *decomp = NULL;
        int out_len = lz_decompress_lh(data, len, &decomp, is_lh6);
        if (out_len > 0 && decomp) {
            // Replace input with decompressed data
            *data_ptr = decomp;
            *len_ptr = out_len;
            return 1;
        }
        free(decomp);
        return -1;
    }
    return 0;
}

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

    // Frame data (YM6 register dumps) — owned copy
    uint8_t *frame_data;
    int   total_frames;
    int   current_frame;
    double frame_remainder;      // fractional sample accumulation
    int   sample_rate;

    // Decompressed LHa data (if file was LHa-compressed), freed on destroy
    uint8_t *raw_data;
    int   raw_data_len;
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
// Frame data for YM4/5/6 is always the LAST total_frames*16 bytes of the file.
// YM3 uses 4-byte frames at a fixed offset after the header.
static double ym6_parse_header(const uint8_t *data, int len,
                                int *out_total_frames, int *out_frame_offset) {
    if (len < 4) return 0;
    const uint8_t m0 = data[0], m1 = data[1], m2 = data[2], m3 = data[3];
    if (m0 != 'Y' || m1 != 'M') return 0;
    if (m2 < '3' || m2 > '6') return 0;  // Only YM3-6
    if (m3 != '!' && m3 != ' ') return 0;

    int total_frames = 0;
    int fps = 50;

    if (m2 == '3') {
        // YM3: magic(4) + frames(4) + 4-byte frames (only 4 registers, delta-encoded)
        if (len < 8) return 0;
        total_frames = (data[4] << 24) | (data[5] << 16) | (data[6] << 8) | data[7];
        if (total_frames <= 0 || len < 8 + total_frames * 4) return 0;
        *out_total_frames = total_frames;
        *out_frame_offset = 8;
        return (double)total_frames / fps;
    }

    if (m2 == '4') {
        // YM4: magic(4) + frames(4) + 16-byte frames
        if (len < 8) return 0;
        total_frames = (data[4] << 24) | (data[5] << 16) | (data[6] << 8) | data[7];
        if (total_frames <= 0) return 0;
        // Frame data is the last total_frames*16 bytes
        int frame_offset = len - total_frames * 16;
        if (frame_offset < 8) return 0;
        *out_total_frames = total_frames;
        *out_frame_offset = frame_offset;
        return (double)total_frames / fps;
    }

    // YM5/6: full metadata header
    //   YM5: magic(4) + name(8) + author(8) + frames(4) + attrs(4) + fps(2) = 30
    //        + extra text (variable, no size field)
    //   YM6: same + loop(4) = 34, + extra text (variable)
    // Frame data is the LAST total_frames*16 bytes of the file
    if (len < 30) return 0;
    total_frames = (data[20] << 24) | (data[21] << 16) | (data[22] << 8) | data[23];
    if (total_frames <= 0) return 0;

    fps = (data[28] << 8) | data[29];
    if (fps <= 0) fps = 50;

    // Calculate frame data offset from end of file
    int frame_offset = len - total_frames * 16;
    int min_header = (m2 == '6') ? 38 : 34;
    if (frame_offset < min_header) return 0;

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
    // 1. Try LHa decompression first (YM files may be LHa-compressed)
    const unsigned char *ym_data = data;
    int ym_len = len;
    int lha_used = ym6_decompress_lha(&ym_data, &ym_len);
    if (lha_used < 0) return 0;  // decompression error

    // 2. Parse YM6/5/4/3 header from (possibly decompressed) data
    int total_frames = 0, frame_offset = 0;
    double duration = ym6_parse_header(ym_data, ym_len, &total_frames, &frame_offset);
    if (duration <= 0 || total_frames <= 0) {
        if (lha_used) free((void *)ym_data);
        return 0;
    }

    ym = (ym6_t*)calloc(1, sizeof(ym6_t));
    if (!ym) {
        if (lha_used) free((void *)ym_data);
        return 0;
    }

    // 3. Store LHa decompressed data (if any) — keep alive for frame_data refs
    if (lha_used) {
        ym->raw_data = (uint8_t *)ym_data;
        ym->raw_data_len = ym_len;
    }

    ym6_reset(ym);

    // 4. Copy frame data — WASM caller may free the input buffer after orz_load returns
    int frames_size = total_frames * 16;
    ym->frame_data = (uint8_t*)malloc(frames_size);
    if (!ym->frame_data) { free(ym); ym = NULL; return 0; }
    memcpy(ym->frame_data, ym_data + frame_offset, frames_size);

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
        free(ym->frame_data);
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
    if (ym) {
        if (ym->frame_data) free(ym->frame_data);
        if (ym->raw_data)   free(ym->raw_data);
        free(ym); ym = NULL;
    }
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
