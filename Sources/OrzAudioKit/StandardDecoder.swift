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

    /// Decode directly to a finalized PCM WAV cache file. Only a bounded
    /// sample-buffer-sized allocation is retained while decoding.
    public func decodeToWAVFile(filePath: String, destinationPath: String) async throws {
        #if canImport(AVFoundation)
        try await decodeWithAVFoundationToFile(filePath: filePath, destinationPath: destinationPath)
        #else
        try await decodeWithFFmpegToFile(filePath: filePath, destinationPath: destinationPath)
        #endif
    }

    #if canImport(AVFoundation)
    private func decodeWithAVFoundationToFile(
        filePath: String,
        destinationPath: String
    ) async throws {
        let asset = AVAsset(url: URL(fileURLWithPath: filePath))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioError.decodeFailed("No audio track in: \(filePath)")
        }
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw AudioError.decodeFailed("Cannot create AVAssetReader for: \(filePath)")
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44100,
        ])
        guard reader.canAdd(output) else {
            throw AudioError.decodeFailed("Cannot add AVAssetReader output")
        }
        reader.add(output)

        let destination = URL(fileURLWithPath: destinationPath)
        let temporary = try makeTemporaryDestination(for: destination)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.write(contentsOf: WAVFile.pcmHeader(
            sampleRate: 44_100, channels: 2, dataSize: 0
        ))

        guard reader.startReading() else {
            throw AudioError.decodeFailed(reader.error?.localizedDescription ?? "AVAssetReader failed to start")
        }
        var dataBytes: UInt64 = 0
        while let sampleBuffer = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let length = CMBlockBufferGetDataLength(block)
            if length == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: length)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length, destination: $0.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr else {
                throw AudioError.decodeFailed("Cannot copy AVFoundation PCM buffer: \(status)")
            }
            try handle.write(contentsOf: Data(bytes))
            dataBytes += UInt64(length)
        }
        guard reader.status == .completed, dataBytes > 0,
              dataBytes <= UInt64(UInt32.max - 36) else {
            throw AudioError.decodeFailed(reader.error?.localizedDescription ?? "AVFoundation decode incomplete")
        }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVFile.pcmHeader(
            sampleRate: 44_100, channels: 2, dataSize: UInt32(dataBytes)
        ))
        try handle.synchronize()
        try handle.close()
        try commit(temporary: temporary, destination: destination)
    }

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

    func decodeWithFFmpegToFile(
        filePath: String,
        destinationPath: String
    ) async throws {
        let destination = URL(fileURLWithPath: destinationPath)
        let temporary = try makeTemporaryDestination(for: destination, createFile: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-y", "-i", filePath,
            "-acodec", "pcm_s16le", "-ar", "44100", "-ac", "2",
            "-f", "wav", temporary.path,
        ]
        let result = try await ProcessRunner.run(process)
        guard result.terminationStatus == 0 else {
            throw AudioError.decodeFailed(result.stderrString ?? "ffmpeg decode failed")
        }
        let mapped = try Data(contentsOf: temporary, options: .mappedIfSafe)
        guard try WAVFile.parse(mapped, includeSamples: false).encoding == .pcm else {
            throw AudioError.invalidPCMData("ffmpeg produced an invalid PCM WAV")
        }
        try commit(temporary: temporary, destination: destination)
    }

    private func makeTemporaryDestination(
        for destination: URL,
        createFile: Bool = true
    ) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp.wav")
        if createFile, !manager.createFile(atPath: temporary.path, contents: nil) {
            throw AudioError.decodeFailed("Cannot create temporary WAV file")
        }
        return temporary
    }

    private func commit(temporary: URL, destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

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
        return try WAVFile.parse(wavData).linearPCM()
    }
}
