import Foundation
import OrzAudioKitCXX

/// Swift-C 桥接层，封装 OrzAudioKitCXX 的 C 解码器接口
///
/// 提供线程安全的 Swift API 来调用 C 层的 `orz_load()` / `orz_render()` / `orz_destroy()`。
/// 所有解码操作在串行队列上执行，避免并发访问 C 单例状态。
///
/// 解码管线：
///   输入文件 Data → orz_load(format, data, len)
///                  → orz_render() 循环 (float32 interleaved)
///                  → float32 → int16 PCM 转换
///                  → PCMData
public enum CDecoderBridge {

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
    /// 在串行队列上执行，线程安全。失败时抛出 AudioError。
    ///
    /// - Parameters:
    ///   - fileData: 原始音频文件二进制数据
    ///   - format: 格式扩展名
    /// - Returns: PCMData（16-bit signed int, little-endian）
    /// - Throws: AudioError.decodeFailed / AudioError.invalidPCMData
    public static func decode(fileData: Data, format: String) throws -> PCMData {
        try serialQueue.sync {
            try fileData.withUnsafeBytes { rawBuf in
                guard let baseAddress = rawBuf.baseAddress, rawBuf.count > 0 else {
                    throw AudioError.invalidPCMData("Empty file data")
                }

                let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
                let result = orz_load(format, ptr, Int32(rawBuf.count))
                guard result != 0 else {
                    throw AudioError.decodeFailed(
                        "C decoder failed to load format '\(format)'"
                    )
                }

                defer { orz_destroy() }

                let sampleRate = Int(orz_get_sample_rate())
                let channels = Int(orz_get_channels())
                let duration = orz_get_duration()

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

                // 渲染循环：分块调用 orz_render，拼接所有 float32 样本
                var buffer = [Float](repeating: 0, count: chunkFrames * channels)
                while true {
                    let rendered = orz_render(&buffer, Int32(chunkFrames))
                    if rendered <= 0 { break }
                    allFloats.append(contentsOf: buffer[0..<Int(rendered) * channels])
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

    private static let serialQueue = DispatchQueue(
        label: "com.orzplayer.cdecoder",
        qos: .userInitiated
    )
}
