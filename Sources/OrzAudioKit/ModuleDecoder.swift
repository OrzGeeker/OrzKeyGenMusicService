import Foundation

/// 模块格式解码器 — 统一使用 ffmpeg CLI 解码
///
/// 目前策略：
/// - 所有模块/芯片格式通过 ffmpeg CLI 解码（系统需安装 ffmpeg + 相关库插件）
/// - macOS 测试环境通过 `brew install ffmpeg` 支持所有格式
/// - Linux/Docker 环境通过 `apt install ffmpeg libopenmpt-dev libgme-dev` 等获取格式支持
///
/// 未来可逐步接入原生 C 库以提升性能，但当前 ffmpeg 已覆盖 90%+ 格式。
public class ModuleDecoder: @unchecked Sendable {

    public init() {}

    /// 解码模块格式为 PCM
    /// - Parameters:
    ///   - filePath: 文件路径
    ///   - format: 音频格式
    /// - Returns: PCM 数据
    public func decode(filePath: String, format: AudioFormat) throws -> PCMData {
        return try decodeWithFFmpeg(filePath: filePath, format: format)
    }

    // MARK: - FFmpeg Universal Decoder

    /// 通过 ffmpeg CLI 解码任意音频格式为 WAV/PCM
    ///
    /// ffmpeg 通过系统库插件（libopenmpt, libgme, libsidplay 等）
    /// 可解码绝大多数模块格式。如需支持所有格式，在 Docker 中安装对应库：
    ///
    ///   apt install ffmpeg libopenmpt-dev libgme-dev libsidplay2-dev \
    ///               libstsound-dev uade123 asap-tools libadplug-dev
    private func decodeWithFFmpeg(filePath: String, format: AudioFormat) throws -> PCMData {
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("orz_mod_\(UUID().uuidString).wav")
            .path
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-y",
            "-i", filePath,
            "-acodec", "pcm_s16le",
            "-ar", "44100",
            "-ac", "2",
            "-f", "wav",
            outputPath
        ]

        // Capture stderr for error diagnostics
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "unknown error"
            throw AudioError.decodeFailed(
                "ffmpeg decode failed for \(format.rawValue): \(errorMsg)"
            )
        }

        let wavData = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        // Standard WAV header is 44 bytes for PCM
        let pcmStart = 44

        guard wavData.count > pcmStart else {
            throw AudioError.invalidPCMData(
                "Decoded WAV too small for \(format.rawValue): \(wavData.count) bytes"
            )
        }

        return PCMData(
            samples: Data(wavData[pcmStart...]),
            sampleRate: 44100,
            channels: 2,
            bitsPerSample: 16
        )
    }
}
