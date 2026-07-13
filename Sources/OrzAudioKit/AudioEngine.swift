import Foundation

/// 音频解码引擎 — 统一的解码 API
///
/// AudioEngine 负责：
/// 1. 判断文件的播放策略（directFile / wasmDecode / serverDecode）
/// 2. 解码音频文件为 PCM 数据
/// 3. 将 PCM 包装为 WAV 格式输出
public class AudioEngine: @unchecked Sendable {

    public enum StreamStrategy: Sendable {
        /// 浏览器原生支持，直接返回原始文件
        case directFile(path: String, mimeType: String)
        /// 前端 WASM 解码，返回原始文件
        case wasmDecode(path: String, format: AudioFormat)
        /// 服务端解码为 WAV
        case serverDecode(path: String, format: AudioFormat)
    }

    public init() {}

    // MARK: - 流策略

    /// 解析文件的流式播放策略
    /// - Parameters:
    ///   - filePath: 文件路径
    ///   - format: 音频格式
    ///   - cachePath: 可选的服务端 WAV 缓存路径
    /// - Returns: 流策略
    public func resolveStreamStrategy(
        filePath: String,
        format: AudioFormat,
        cachePath: String? = nil
    ) -> StreamStrategy {
        switch format.playStrategy {
        case .directFile:
            return .directFile(path: filePath, mimeType: format.mimeType)
        case .wasmDecode:
            return .wasmDecode(path: filePath, format: format)
        case .serverDecode:
            return .serverDecode(path: filePath, format: format)
        }
    }

    // MARK: - 解码

    /// 解码音频文件为 PCM 数据
    /// - Parameters:
    ///   - filePath: 文件路径
    ///   - format: 音频格式
    /// - Returns: PCM 数据
    /// - Throws: 解码错误
    private let standardDecoder = StandardDecoder()
    private let moduleDecoder = ModuleDecoder()

    public func decodeToPCM(filePath: String, format: AudioFormat) throws -> PCMData {
        switch format {
        case .xm, .mod, .it, .s3m, .mo3, .mtm,
             .nsf, .spc, .sid, .sc68, .hsc, .ym,
             .ahx, .amd, .fc13, .fc14, .sap,
             .rad, .d00, .v2m, .bp:
            return try moduleDecoder.decode(filePath: filePath, format: format)
        case .mp3, .ogg, .wav, .flac, .mid, .m4a, .aac:
            return try standardDecoder.decode(filePath: filePath, format: format)
        }
    }

    /// 解码音频文件并包装为 WAV 格式
    public func decodeToWAV(filePath: String, format: AudioFormat) throws -> Data {
        let pcm = try decodeToPCM(filePath: filePath, format: format)
        return pcm.encodeWAV()
    }
}
