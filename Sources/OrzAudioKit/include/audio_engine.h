#ifndef ORZ_AUDIO_ENGINE_H
#define ORZ_AUDIO_ENGINE_H

// 每个解码器实现的统一接口
typedef struct {
    const char *name;       // 日志用
    int  (*load)(const unsigned char *data, int len);
    double (*get_duration)();
    int   (*get_sample_rate)();
    int   (*get_channels)();
    int   (*render)(float *out, int frames);
    void  (*destroy)();
} Decoder;

// 注册解码器到调度表
void orz_register_decoder(const char *extensions, const Decoder *decoder);

// 统一入口（EMSCRIPTEN_KEEPALIVE 在 orz_dispatch.c 中标记）
int         orz_load(const char *format, const unsigned char *data, int len);
double      orz_get_duration();
int         orz_get_sample_rate();
int         orz_get_channels();
int         orz_render(float *out, int frames);
void        orz_destroy();
int         orz_can_decode(const char *format);

#endif /* ORZ_AUDIO_ENGINE_H */
