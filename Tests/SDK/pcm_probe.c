#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "orz_audio_core.h"

static unsigned char *read_file(const char *path, size_t *size) {
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    if (fseek(file, 0, SEEK_END) != 0) { fclose(file); return NULL; }
    long length = ftell(file);
    if (length <= 0 || fseek(file, 0, SEEK_SET) != 0) { fclose(file); return NULL; }
    unsigned char *data = malloc((size_t)length);
    if (!data || fread(data, 1, (size_t)length, file) != (size_t)length) {
        free(data); fclose(file); return NULL;
    }
    fclose(file);
    *size = (size_t)length;
    return data;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: pcm_probe INPUT FORMAT MAX_FRAMES OUTPUT_PREFIX\n");
        return 2;
    }
    size_t input_size = 0;
    unsigned char *input = read_file(argv[1], &input_size);
    if (!input) { fprintf(stderr, "cannot read %s: %s\n", argv[1], strerror(errno)); return 3; }

    OrzDecoderHandle *decoder = NULL;
    orz_status status = orz_decoder_create_memory(input, input_size, argv[2], NULL, &decoder);
    free(input);
    if (status != ORZ_OK) {
        fprintf(stderr, "%s: create failed: %s\n", argv[2], orz_status_message(status));
        return 4;
    }

    orz_stream_info info = {0};
    info.struct_size = sizeof(info);
    info.abi_version = ORZ_ABI_VERSION;
    status = orz_decoder_get_stream_info(decoder, &info);
    if (status != ORZ_OK || info.channels == 0 || info.channels > 8) {
        fprintf(stderr, "%s: invalid stream info\n", argv[2]);
        orz_decoder_destroy_v1(decoder);
        return 5;
    }

    uint64_t requested = strtoull(argv[3], NULL, 10);
    if (requested == 0 || requested > UINT32_MAX) requested = 220500;
    char pcm_path[4096], json_path[4096];
    snprintf(pcm_path, sizeof(pcm_path), "%s.f32", argv[4]);
    snprintf(json_path, sizeof(json_path), "%s.json", argv[4]);
    FILE *pcm = fopen(pcm_path, "wb");
    if (!pcm) { orz_decoder_destroy_v1(decoder); return 6; }

    const uint32_t chunk_frames = 4096;
    float *buffer = calloc((size_t)chunk_frames * info.channels, sizeof(float));
    if (!buffer) {
        fclose(pcm);
        orz_decoder_destroy_v1(decoder);
        return 9;
    }
    uint64_t total = 0;
    double peak = 0.0;
    double sum_squares = 0.0;
    while (total < requested) {
        uint32_t want = (uint32_t)((requested - total) < chunk_frames ? requested - total : chunk_frames);
        uint32_t rendered = 0;
        status = orz_decoder_render_f32(decoder, buffer, want, &rendered);
        if (status != ORZ_OK && status != ORZ_END_OF_STREAM) break;
        for (size_t i = 0; i < (size_t)rendered * info.channels; ++i) {
            double magnitude = buffer[i] < 0 ? -(double)buffer[i] : (double)buffer[i];
            if (magnitude > peak) peak = magnitude;
            sum_squares += (double)buffer[i] * (double)buffer[i];
        }
        if (fwrite(buffer, sizeof(float) * info.channels, rendered, pcm) != rendered) { status = ORZ_ERROR_INTERNAL; break; }
        total += rendered;
        if (status == ORZ_END_OF_STREAM || rendered == 0) break;
    }
    free(buffer);
    fclose(pcm);
    orz_decoder_destroy_v1(decoder);
    if (status != ORZ_OK && status != ORZ_END_OF_STREAM) {
        fprintf(stderr, "%s: render failed: %s\n", argv[2], orz_status_message(status));
        return 7;
    }

    FILE *json = fopen(json_path, "w");
    if (!json) return 8;
    fprintf(json, "{\"format\":\"%s\",\"sampleRate\":%u,\"channels\":%u,"
                  "\"duration\":%.9f,\"frames\":%llu,\"peak\":%.9g,\"meanSquare\":%.12g}\n",
            argv[2], info.sample_rate, info.channels, info.duration_seconds,
            (unsigned long long)total, peak,
            total ? sum_squares / ((double)total * info.channels) : 0.0);
    fclose(json);
    return 0;
}
