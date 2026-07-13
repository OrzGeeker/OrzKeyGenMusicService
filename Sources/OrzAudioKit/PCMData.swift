import Foundation

/// PCM 数据结构，包含原始音频采样数据
public struct PCMData: Sendable {
    /// 16-bit 有符号整型 PCM 数据
    public let samples: Data
    /// 采样率 (Hz)
    public let sampleRate: Int
    /// 声道数
    public let channels: Int
    /// 位深度
    public let bitsPerSample: Int

    public init(samples: Data = Data(), sampleRate: Int = 44100, channels: Int = 2, bitsPerSample: Int = 16) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }

    /// 编码为 WAV 格式数据（含 RIFF header）
    public func encodeWAV() -> Data {
        var data = Data()

        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = samples.count

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Data($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        let fmtSize = UInt32(16)
        data.append(contentsOf: withUnsafeBytes(of: fmtSize.littleEndian) { Data($0) })
        let audioFormat = UInt16(1) // PCM
        data.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        let numChannels = UInt16(channels)
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        let sampRate = UInt32(sampleRate)
        data.append(contentsOf: withUnsafeBytes(of: sampRate.littleEndian) { Data($0) })
        let byteRte = UInt32(byteRate)
        data.append(contentsOf: withUnsafeBytes(of: byteRte.littleEndian) { Data($0) })
        let blockAlgn = UInt16(blockAlign)
        data.append(contentsOf: withUnsafeBytes(of: blockAlgn.littleEndian) { Data($0) })
        let bitsPerSamp = UInt16(bitsPerSample)
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSamp.littleEndian) { Data($0) })

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Data($0) })
        data.append(samples)

        return data
    }
}
