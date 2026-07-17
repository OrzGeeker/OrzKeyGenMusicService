import Foundation
import OrzAudioKitCXX

/// Swift-C 桥接层，封装 OrzAudioKitCXX 的 C 解码器接口
///
/// 提供线程安全的 Swift API 来调用 C 层的实例化 decoder handle。
/// 每次调用持有独立 C decoder handle，可安全并行解码。
///
/// 解码管线：
///   输入文件 Data → orz_decoder_create(format, data, len)
///                  → orz_decoder_render() 循环 (float32 interleaved)
///                  → float32 → int16 PCM 转换
///                  → PCMData
public enum CDecoderBridge {

    /// Reads decoder metadata without rendering PCM. This is suitable for
    /// library scans and duration backfills because it uses an independent
    /// decoder instance and releases it immediately.
    public static func duration(filePath: String, format: String) throws -> Double {
        let source = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
        guard !source.isEmpty, source.count <= Int(Int32.max) else {
            throw AudioError.invalidPCMData("Invalid decoder input size: \(source.count)")
        }
        return try source.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw AudioError.invalidPCMData("Empty file data")
            }
            let decoder = format.withCString {
                orz_decoder_create(
                    $0,
                    baseAddress.assumingMemoryBound(to: UInt8.self),
                    Int32(rawBuffer.count)
                )
            }
            guard let decoder else {
                throw AudioError.decodeFailed("C decoder failed to load format '\(format)'")
            }
            defer { orz_decoder_destroy(decoder) }
            let value = orz_decoder_get_duration(decoder)
            guard value.isFinite, value > 0 else {
                throw AudioError.decodeFailed("Decoder returned invalid duration \(value)")
            }
            return value
        }
    }

    /// Decode directly into a PCM WAV file without retaining the complete
    /// float or int16 stream in memory. The destination is committed with a
    /// same-directory rename only after the WAV header has been finalized.
    public static func decodeToWAVFile(
        filePath: String,
        format: String,
        destinationPath: String,
        subsong: Int = 0
    ) throws {
        let source = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
            guard !source.isEmpty, source.count <= Int(Int32.max) else {
                throw AudioError.invalidPCMData("Invalid decoder input size: \(source.count)")
            }

            try source.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    throw AudioError.invalidPCMData("Empty file data")
                }
                let decoder = format.withCString {
                    orz_decoder_create(
                        $0,
                        baseAddress.assumingMemoryBound(to: UInt8.self),
                        Int32(rawBuffer.count)
                    )
                }
                guard let decoder else {
                    throw AudioError.decodeFailed("C decoder failed to load format '\(format)'")
                }
                defer { orz_decoder_destroy(decoder) }
                if subsong > 0, orz_decoder_select_subsong(decoder, Int32(subsong)) != 0 {
                    throw AudioError.decodeFailed("Decoder does not support subsong \(subsong)")
                }

                let sampleRate = Int(orz_decoder_get_sample_rate(decoder))
                let channels = Int(orz_decoder_get_channels(decoder))
                let duration = orz_decoder_get_duration(decoder)
                guard sampleRate > 0, channels > 0, duration > 0,
                      channels <= Int(UInt16.max), sampleRate <= Int(UInt32.max) else {
                    throw AudioError.invalidPCMData(
                        "Invalid decoder metadata: rate=\(sampleRate) ch=\(channels) duration=\(duration)"
                    )
                }

                let destination = URL(fileURLWithPath: destinationPath)
                let temporary = destination.deletingLastPathComponent()
                    .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
                let fileManager = FileManager.default
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
                    throw AudioError.decodeFailed("Cannot create temporary WAV file")
                }
                defer { try? fileManager.removeItem(at: temporary) }

                let handle = try FileHandle(forWritingTo: temporary)
                defer { try? handle.close() }
                try handle.write(contentsOf: WAVFile.pcmHeader(
                    sampleRate: sampleRate, channels: channels, dataSize: 0
                ))

                let estimatedFrames = Int(duration * Double(sampleRate))
                let maxRenderFrames = max(estimatedFrames * 2, sampleRate * 30)
                let chunkFrames = 4096
                var floats = [Float](repeating: 0, count: chunkFrames * channels)
                var int16 = [Int16](repeating: 0, count: chunkFrames * channels)
                var totalFrames = 0
                var dataBytes: UInt64 = 0

                while totalFrames < maxRenderFrames {
                    let request = min(chunkFrames, maxRenderFrames - totalFrames)
                    let rendered = Int(orz_decoder_render(decoder, &floats, Int32(request)))
                    if rendered <= 0 { break }
                    let sampleCount = rendered * channels
                    for index in 0..<sampleCount {
                        let value = max(-1.0, min(1.0, Double(floats[index])))
                        int16[index] = Int16(value * 32767.0).littleEndian
                    }
                    let bytes = int16.withUnsafeBytes {
                        Data(bytes: $0.baseAddress!, count: sampleCount * MemoryLayout<Int16>.size)
                    }
                    try handle.write(contentsOf: bytes)
                    dataBytes += UInt64(bytes.count)
                    totalFrames += rendered
                }

                guard totalFrames > 0, dataBytes <= UInt64(UInt32.max - 36) else {
                    throw AudioError.decodeFailed("Decoded WAV is empty or exceeds RIFF size limits")
                }
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: WAVFile.pcmHeader(
                    sampleRate: sampleRate,
                    channels: channels,
                    dataSize: UInt32(dataBytes)
                ))
                try handle.synchronize()
                try handle.close()

                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try fileManager.moveItem(at: temporary, to: destination)
                }
        }
    }

    /// 检查 C 引擎是否能解码指定格式
    /// - Parameter format: 格式扩展名（如 "xm", "sid", "ym"）
    /// - Returns: true 表示有已注册的解码器
    public static func canDecode(format: String) -> Bool {
        format.withCString { cFormat in
            orz_can_decode(cFormat) != 0
        }
    }

    /// 解码原始音频文件数据为 PCM
    ///
    /// 每次调用使用独立句柄，线程安全。失败时抛出 AudioError。
    ///
    /// - Parameters:
    ///   - fileData: 原始音频文件二进制数据
    ///   - format: 格式扩展名
    /// - Returns: PCMData（16-bit signed int, little-endian）
    /// - Throws: AudioError.decodeFailed / AudioError.invalidPCMData
    public static func decode(fileData: Data, format: String, subsong: Int = 0) throws -> PCMData {
        try fileData.withUnsafeBytes { rawBuf in
                guard let baseAddress = rawBuf.baseAddress, rawBuf.count > 0 else {
                    throw AudioError.invalidPCMData("Empty file data")
                }

                let decoder = format.withCString {
                    orz_decoder_create(
                        $0,
                        baseAddress.assumingMemoryBound(to: UInt8.self),
                        Int32(rawBuf.count)
                    )
                }
                guard let decoder else {
                    throw AudioError.decodeFailed(
                        "C decoder failed to load format '\(format)'"
                    )
                }

                defer { orz_decoder_destroy(decoder) }
                if subsong > 0, orz_decoder_select_subsong(decoder, Int32(subsong)) != 0 {
                    throw AudioError.decodeFailed("Decoder does not support subsong \(subsong)")
                }

                let sampleRate = Int(orz_decoder_get_sample_rate(decoder))
                let channels = Int(orz_decoder_get_channels(decoder))
                let duration = orz_decoder_get_duration(decoder)

                guard sampleRate > 0, channels > 0, duration > 0 else {
                    throw AudioError.invalidPCMData(
                        "Invalid decoder metadata: rate=\(sampleRate) ch=\(channels) duration=\(duration)"
                    )
                }

                // 预估帧数
                let estimatedFrames = Int(duration * Double(sampleRate))
                let chunkFrames = 4096
                var allFloats = [Float]()
                allFloats.reserveCapacity(estimatedFrames * channels)

                // 渲染循环：分块调用 handle API，拼接所有 float32 样本
                // maxRenderFrames 防止解码器不返回 0 时无限循环
                let maxRenderFrames = max(estimatedFrames * 2, 44100 * 30) // 至少 30 秒的上限
                var totalRendered: Int = 0
                var buffer = [Float](repeating: 0, count: chunkFrames * channels)
                while totalRendered < maxRenderFrames {
                    let rendered = orz_decoder_render(decoder, &buffer, Int32(chunkFrames))
                    if rendered <= 0 { break }
                    allFloats.append(contentsOf: buffer[0..<Int(rendered) * channels])
                    totalRendered += Int(rendered)
                }

                guard !allFloats.isEmpty else {
                    throw AudioError.decodeFailed("C decoder rendered 0 frames for '\(format)'")
                }

                // float32 interleaved → int16 interleaved
                var int16Samples = Data(capacity: allFloats.count * 2)
                for sample in allFloats {
                    let clamped = max(-1.0, min(1.0, Double(sample)))
                    let int16Val = Int16(clamped * 32767.0)
                    withUnsafeBytes(of: int16Val.littleEndian) { int16Samples.append(contentsOf: $0) }
                }

                return PCMData(
                    samples: int16Samples,
                    sampleRate: sampleRate,
                    channels: channels,
                    bitsPerSample: 16
                )
        }
    }

    /// 解码磁盘文件为 PCM
    /// - Parameters:
    ///   - filePath: 文件路径
    ///   - format: 音频格式
    /// - Returns: PCMData
    /// - Throws: AudioError
    public static func decode(filePath: String, format: AudioFormat) throws -> PCMData {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        return try decode(fileData: data, format: format.rawValue)
    }

    /// 解码磁盘文件为 PCM（字符串格式名）
    /// - Parameters:
    ///   - filePath: 文件路径
    ///   - format: 格式扩展名字符串
    /// - Returns: PCMData
    /// - Throws: AudioError
    public static func decode(filePath: String, format: String) throws -> PCMData {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        return try decode(fileData: data, format: format)
    }

}
