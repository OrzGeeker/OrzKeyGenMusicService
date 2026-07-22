import Foundation

/// 音频指纹器 — 用于音频内容去重
///
/// 指纹策略（自动降级）：
/// 1. Chromaprint fpcalc CLI — 真正的音频指纹，感知哈希
/// 2. ffmpeg sha256 降级 — 文件级哈希
public class AudioFingerprinter: @unchecked Sendable {

    public enum FingerprintError: LocalizedError {
        case fpcalcFailed(String)
        case ffmpegFailed(String)
        case invalidAudioData

        public var errorDescription: String? {
            switch self {
            case .fpcalcFailed(let msg):   return "fpcalc failed: \(msg)"
            case .ffmpegFailed(let msg):   return "ffmpeg fingerprint failed: \(msg)"
            case .invalidAudioData:        return "Invalid audio data for fingerprinting"
            }
        }
    }

    public init() {}

    /// 从 PCM 数据生成音频指纹
    /// - Parameter pcmData: PCM 数据
    /// - Returns: 指纹字符串（Chromaprint base64，不可用时回退到 SHA-256）
    public func generateFingerprint(pcmData: PCMData) async throws -> String {
        // 写入临时 WAV 文件用于 fpcalc
        let wavData = pcmData.encodeWAV()
        let tmpPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("orz_fp_\(UUID().uuidString).wav")
            .path
        try wavData.write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // 策略 1: fpcalc (Chromaprint 原生指纹)
        if let fingerprint = try? await generateWithFPCalc(filePath: tmpPath) {
            return fingerprint
        }

        // 策略 2: SHA-256 降级
        return try await generateWithSHA256(filePath: tmpPath)
    }

    /// 从音频文件直接生成指纹
    /// - Parameter filePath: 音频文件路径
    /// - Returns: 指纹字符串
    public func generateFingerprintFromFile(filePath: String) async throws -> String {
        // 策略 1: fpcalc
        if let fingerprint = try? await generateWithFPCalc(filePath: filePath) {
            return fingerprint
        }

        // 策略 2: 先用 ffmpeg 转 WAV 再 fpcalc
        let wavPath = try await convertToWAV(filePath: filePath)
        defer { try? FileManager.default.removeItem(atPath: wavPath) }

        if let fingerprint = try? await generateWithFPCalc(filePath: wavPath) {
            return fingerprint
        }

        // 策略 3: SHA-256 降级
        return try await generateWithSHA256(filePath: filePath)
    }

    /// 对比两个指纹的相似度 (0.0 ~ 1.0)
    ///
    /// Chromaprint 指纹基于感知哈希，长度接近时相似度有意义。
    /// SHA-256 降级时只做精确匹配（要么完全相同要么完全不同）。
    public func compare(fingerprint1: String, fingerprint2: String) -> Double {
        // Chromaprint 指纹格式: "AQAA..." base64 字符串
        if fingerprint1.hasPrefix("AQ") || fingerprint2.hasPrefix("AQ") {
            return compareChromaprint(fingerprint1, fingerprint2)
        }

        // SHA-256 降级: 只做精确匹配
        return fingerprint1 == fingerprint2 ? 1.0 : 0.0
    }

    // MARK: - Private

    /// 使用 fpcalc CLI 生成 Chromaprint 指纹
    private func generateWithFPCalc(filePath: String) async throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["fpcalc", "-raw", "-length", "30", filePath]

        let result = try await ProcessRunner.run(process, timeout: 10)

        guard result.terminationStatus == 0,
              let output = result.stdoutString
        else { return nil }

        // fpcalc 输出格式: "FINGERPRINT=..."
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("FINGERPRINT=") {
                return String(line.dropFirst("FINGERPRINT=".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        return nil
    }

    /// 使用 ffmpeg 将文件转为 WAV
    private func convertToWAV(filePath: String) async throws -> String {
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("orz_conv_\(UUID().uuidString).wav")
            .path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-y", "-i", filePath,
            "-acodec", "pcm_s16le", "-ar", "44100", "-ac", "2",
            "-f", "wav", outputPath
        ]

        let result = try await ProcessRunner.run(process, timeout: 20)

        guard result.terminationStatus == 0 else {
            throw FingerprintError.ffmpegFailed("ffmpeg convert to WAV failed")
        }

        return outputPath
    }

    /// SHA-256 降级
    private func generateWithSHA256(filePath: String) async throws -> String {
        let result = try await ProcessRunner.execute(arguments: ["shasum", "-a", "256", filePath])
        guard let hash = result.split(separator: " ").first else {
            throw FingerprintError.ffmpegFailed("Cannot compute SHA-256")
        }
        return "sha256_\(hash)"
    }

    /// Chromaprint 指纹相似度比较（Hamming 距离近似）
    private func compareChromaprint(_ fp1: String, _ fp2: String) -> Double {
        guard !fp1.isEmpty, !fp2.isEmpty else { return 0 }

        // Chromaprint raw 格式的指纹是 base64 编码的 32 位整数数组
        // 简单近似：比较长度和前缀
        let len1 = fp1.count
        let len2 = fp2.count

        if abs(len1 - len2) > 5 { return 0 }

        // 计算相同字符比例作为粗略相似度
        let minLen = min(len1, len2)
        let matches = zip(fp1.prefix(minLen), fp2.prefix(minLen)).filter { $0 == $1 }.count

        return Double(matches) / Double(max(len1, len2))
    }
}
