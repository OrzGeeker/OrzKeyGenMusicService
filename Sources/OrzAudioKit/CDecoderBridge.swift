import Foundation

/// Compatibility facade used by the service. All production operations route
/// through the stable OrzAudioCore ABI v1 Swift binding.
public enum CDecoderBridge {
    public static func duration(filePath: String, format: String) throws -> Double {
        let source = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
        let value = try AudioDecoder(data: source, format: format).info.duration
        guard value.isFinite, value > 0 else {
            throw AudioError.decodeFailed("Decoder returned invalid duration \(value)")
        }
        return value
    }

    public static func canDecode(format: String) -> Bool {
        DecoderManifest.decodableFormatIDs.contains(format.lowercased()) &&
            AudioDecoder.supportedFormats.contains { $0.id == format.lowercased() }
    }

    public static func decode(fileData: Data, format: String, subsong: Int = 0) throws -> PCMData {
        let decoder = try AudioDecoder(data: fileData, format: format, subsong: subsong)
        let info = decoder.info
        guard info.sampleRate > 0, info.channels > 0, info.duration > 0 else {
            throw AudioError.invalidPCMData(
                "Invalid decoder metadata: rate=\(info.sampleRate) ch=\(info.channels) duration=\(info.duration)"
            )
        }
        let estimatedFrames = Int(info.duration * Double(info.sampleRate))
        let maxRenderFrames = max(estimatedFrames * 2, info.sampleRate * 30)
        var totalFrames = 0
        var pcm = Data(capacity: min(maxRenderFrames * info.channels * 2, 64 * 1024 * 1024))
        while totalFrames < maxRenderFrames {
            let samples = try decoder.render(maxFrames: min(4096, maxRenderFrames - totalFrames))
            if samples.isEmpty { break }
            appendInt16(samples, to: &pcm)
            totalFrames += samples.count / info.channels
        }
        guard totalFrames > 0 else {
            throw AudioError.decodeFailed("C decoder rendered 0 frames for '\(format)'")
        }
        return PCMData(samples: pcm, sampleRate: info.sampleRate, channels: info.channels, bitsPerSample: 16)
    }

    public static func decodeToWAVFile(
        filePath: String,
        format: String,
        destinationPath: String,
        subsong: Int = 0
    ) throws {
        let source = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
        let decoder = try AudioDecoder(data: source, format: format, subsong: subsong)
        let info = decoder.info
        guard info.sampleRate > 0, info.channels > 0, info.duration > 0,
              info.channels <= Int(UInt16.max), info.sampleRate <= Int(UInt32.max) else {
            throw AudioError.invalidPCMData("Invalid decoder metadata")
        }

        let destination = URL(fileURLWithPath: destinationPath)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw AudioError.decodeFailed("Cannot create temporary WAV file")
        }
        defer { try? fileManager.removeItem(at: temporary) }

        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        try output.write(contentsOf: WAVFile.pcmHeader(sampleRate: info.sampleRate, channels: info.channels, dataSize: 0))
        let estimatedFrames = Int(info.duration * Double(info.sampleRate))
        let maxRenderFrames = max(estimatedFrames * 2, info.sampleRate * 30)
        var totalFrames = 0
        var dataBytes: UInt64 = 0
        while totalFrames < maxRenderFrames {
            let samples = try decoder.render(maxFrames: min(4096, maxRenderFrames - totalFrames))
            if samples.isEmpty { break }
            var bytes = Data(capacity: samples.count * 2)
            appendInt16(samples, to: &bytes)
            try output.write(contentsOf: bytes)
            dataBytes += UInt64(bytes.count)
            totalFrames += samples.count / info.channels
        }
        guard totalFrames > 0, dataBytes <= UInt64(UInt32.max - 36) else {
            throw AudioError.decodeFailed("Decoded WAV is empty or exceeds RIFF size limits")
        }
        try output.seek(toOffset: 0)
        try output.write(contentsOf: WAVFile.pcmHeader(sampleRate: info.sampleRate, channels: info.channels,
                                                       dataSize: UInt32(dataBytes)))
        try output.synchronize()
        try output.close()
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    public static func decode(filePath: String, format: AudioFormat) throws -> PCMData {
        try decode(fileData: Data(contentsOf: URL(fileURLWithPath: filePath)), format: format.rawValue)
    }

    public static func decode(filePath: String, format: String) throws -> PCMData {
        try decode(fileData: Data(contentsOf: URL(fileURLWithPath: filePath)), format: format)
    }

    private static func appendInt16(_ samples: [Float], to output: inout Data) {
        for sample in samples {
            var value = Int16(max(-1.0, min(1.0, Double(sample))) * 32767.0).littleEndian
            withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
        }
    }
}
