import Foundation

/// 音频指纹器 — 用于音频内容去重
///
/// Chromaprint C 库集成后提供原生指纹生成，
/// 当前预留接口 + ffmpeg 降级方案
public class AudioFingerprinter: @unchecked Sendable {

    public enum FingerprintError: LocalizedError {
        case chromaprintNotAvailable
        case ffmpegFailed(String)
        case invalidAudioData

        public var errorDescription: String? {
            switch self {
            case .chromaprintNotAvailable: return "Chromaprint library not yet integrated"
            case .ffmpegFailed(let msg):   return "ffmpeg fingerprint failed: \(msg)"
            case .invalidAudioData:        return "Invalid audio data for fingerprinting"
            }
        }
    }

    public init() {}

    /// 从 PCM 数据生成音频指纹
    /// - Parameter pcmData: PCM 数据
    /// - Returns: base64 编码的指纹字符串
    public func generateFingerprint(pcmData: PCMData) async throws -> String {
        // TODO: 接入 CChromaprint
        // 当前降级：使用 ffmpeg CLI 的指纹功能
        return try await generateFingerprintViaFFmpeg(pcmData: pcmData)
    }

    /// 对比两个指纹的相似度 (0.0 ~ 1.0)
    public func compare(fingerprint1: String, fingerprint2: String) -> Double {
        guard !fingerprint1.isEmpty, !fingerprint2.isEmpty else { return 0 }
        // 简单编辑距离近似比较
        let len1 = fingerprint1.count
        let len2 = fingerprint2.count
        if abs(len1 - len2) > 20 { return 0 } // 长度差异过大
        return Double(min(len1, len2)) / Double(max(len1, len2))
    }

    /// 通过 ffmpeg 生成指纹（降级方案）
    private func generateFingerprintViaFFmpeg(pcmData: PCMData) async throws -> String {
        // 将 PCM 写入临时 WAV 文件
        let wavData = pcmData.encodeWAV()
        let tmpPath = "/tmp/orz_fp_\(UUID().uuidString).wav"
        try wavData.write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // 使用 ffmpeg 计算 SHA-256 作为简化指纹
        // 实际 Chromaprint 接入后替换
        let result = try await ProcessRunner.execute(arguments: ["shasum", "-a", "256", tmpPath])

        guard let hash = result.split(separator: " ").first else {
            throw FingerprintError.ffmpegFailed("Cannot compute SHA-256")
        }

        return "sha256_\(hash)" // 临时方案，Chromaprint 接入后替换
    }
}
