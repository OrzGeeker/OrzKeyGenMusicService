export declare const ORZ_ABI_VERSION = 65536;
export declare const ORZ_OK = 0;
export declare const ORZ_END_OF_STREAM = 1;
export interface EmscriptenOrzModule {
    HEAPU8: Uint8Array;
    HEAPU32: Uint32Array;
    HEAPF64: Float64Array;
    HEAPF32: Float32Array;
    _malloc(size: number): number;
    _free(pointer: number): void;
    _orz_abi_version(): number;
    _orz_decoder_create_memory(data: number, size: number, format: number, config: number, output: number): number;
    _orz_decoder_get_stream_info(decoder: number, output: number): number;
    _orz_decoder_render_f32(decoder: number, output: number, frames: number, rendered: number): number;
    _orz_decoder_seek(decoder: number, milliseconds: number): number;
    _orz_decoder_select_subsong_v1(decoder: number, subsong: number): number;
    _orz_decoder_reset(decoder: number): number;
    _orz_decoder_cancel(decoder: number): number;
    _orz_decoder_destroy_v1(decoder: number): void;
    UTF8ToString(pointer: number): string;
    stringToUTF8(value: string, pointer: number, capacity: number): void;
    lengthBytesUTF8(value: string): number;
}
export interface StreamInfo {
    sampleRate: number;
    channels: number;
    duration: number;
    subsongCount: number;
    capabilities: number;
}
export declare class OrzAudioCoreError extends Error {
    readonly status: number;
    constructor(status: number, operation: string);
}
export declare class AudioDecoder {
    #private;
    private readonly module;
    readonly info: StreamInfo;
    constructor(module: EmscriptenOrzModule, handle: number);
    render(maxFrames: number): Float32Array;
    seek(milliseconds: number): void;
    selectSubsong(index: number): void;
    reset(): void;
    cancel(): void;
    close(): void;
}
export declare function createDecoder(module: EmscriptenOrzModule, data: Uint8Array, format: string): AudioDecoder;
