import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// 标准音频格式解码器
///
/// macOS: 使用 AVFoundation
/// Linux: 使用 ffmpeg CLI 作为降级
public class StandardDecoder: @unchecked Sendable {

    public init() {}

    /// 解码标准音频格式为 PCM 数据
    /// - Parameters:
    ///   - filePath: 文件路径
    ///   - format: 音频格式
    /// - Returns: PCM 数据
    public func decode(filePath: String, format: AudioFormat) async throws -> PCMData {
        #if canImport(AVFoundation)
        return try await decodeWithAVFoundation(filePath: filePath)
        #else
        return try await decodeWithFFmpegCLI(filePath: filePath)
        #endif
    }

    #if canImport(AVFoundation)
    /// 使用 AVFoundation 解码
    private func decodeWithAVFoundation(filePath: String) async throws -> PCMData {
        let url = URL(fileURLWithPath: filePath)
        let asset = AVAsset(url: url)

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw AudioError.decodeFailed("Cannot create AVAssetReader for: \(filePath)")
        }

        let tracks = try? await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks?.first
        else {
            throw AudioError.decodeFailed("Cannot create AVAssetReader for: \(filePath)")
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44100,
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()

        var samples = Data()
        while let sampleBuffer = output.copyNextSampleBuffer(),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            if let dataPointer = dataPointer {
                dataPointer.withMemoryRebound(to: UInt8.self, capacity: length) { ptr in
                    samples.append(ptr, count: length)
                }
            }
        }

        return PCMData(samples: samples, sampleRate: 44100, channels: 2, bitsPerSample: 16)
    }
    #endif

    /// 使用 ffmpeg CLI 解码（Linux 降级）
    private func decodeWithFFmpegCLI(filePath: String) async throws -> PCMData {
        let outputPath = "/tmp/orz_audio_\(UUID().uuidString).wav"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-y", "-i", filePath,
            "-acodec", "pcm_s16le", "-ar", "44100", "-ac", "2",
            "-f", "wav", outputPath
        ]

        let result = try await ProcessRunner.run(process)

        guard result.terminationStatus == 0 else {
            throw AudioError.decodeFailed("ffmpeg failed for: \(filePath)")
        }

        let wavData = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        // Strip WAV header (44 bytes for standard PCM WAV)
        let pcmStart = 44
        guard wavData.count > pcmStart else {
            throw AudioError.invalidPCMData("WAV file too small")
        }
        let pcmData = wavData[pcmStart...]

        return PCMData(
            samples: Data(pcmData),
            sampleRate: 44100,
            channels: 2,
            bitsPerSample: 16
        )
    }
}
