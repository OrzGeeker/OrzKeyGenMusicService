import Foundation

public enum WAVEncoding: Equatable, Sendable {
    case pcm
    case ieeeFloat
    case compressed(formatTag: UInt16)
}

public struct WAVFile: Sendable {
    public let encoding: WAVEncoding
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    public let blockAlign: Int
    public let samples: Data

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
        UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    public static func parse(_ data: Data, includeSamples: Bool = true) throws -> WAVFile {
        guard data.count >= 12,
              data[0..<4].elementsEqual("RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8) else {
            throw AudioError.invalidPCMData("Invalid RIFF/WAVE header")
        }

        let declaredSize = Int(u32(data, 4)) + 8
        guard declaredSize >= 12, declaredSize <= data.count else {
            throw AudioError.invalidPCMData("Truncated RIFF container")
        }

        var formatTag: UInt16?
        var channels = 0
        var sampleRate = 0
        var blockAlign = 0
        var bitsPerSample = 0
        var dataRange: Range<Int>?
        var offset = 12

        while offset <= declaredSize - 8 {
            let chunkID = data[offset..<(offset + 4)]
            let chunkSize = Int(u32(data, offset + 4))
            let payload = offset + 8
            guard chunkSize <= declaredSize - payload else {
                throw AudioError.invalidPCMData("Truncated WAV chunk")
            }

            if chunkID.elementsEqual("fmt ".utf8) {
                guard chunkSize >= 16 else {
                    throw AudioError.invalidPCMData("WAV fmt chunk is too small")
                }
                var tag = u16(data, payload)
                channels = Int(u16(data, payload + 2))
                sampleRate = Int(u32(data, payload + 4))
                blockAlign = Int(u16(data, payload + 12))
                bitsPerSample = Int(u16(data, payload + 14))
                if tag == 0xFFFE {
                    guard chunkSize >= 40, u16(data, payload + 16) >= 22 else {
                        throw AudioError.invalidPCMData("Invalid WAVE_FORMAT_EXTENSIBLE fmt chunk")
                    }
                    tag = u16(data, payload + 24)
                }
                formatTag = tag
            } else if chunkID.elementsEqual("data".utf8), dataRange == nil {
                dataRange = payload..<(payload + chunkSize)
            }

            let padded = chunkSize + (chunkSize & 1)
            guard padded <= declaredSize - payload else {
                throw AudioError.invalidPCMData("Missing WAV chunk padding")
            }
            offset = payload + padded
        }

        guard let tag = formatTag, let range = dataRange,
              channels > 0, sampleRate > 0, blockAlign > 0, bitsPerSample > 0 else {
            throw AudioError.invalidPCMData("WAV is missing valid fmt or data chunks")
        }
        guard range.count % blockAlign == 0 else {
            throw AudioError.invalidPCMData("WAV data is not aligned to complete sample frames")
        }

        let encoding: WAVEncoding
        switch tag {
        case 1: encoding = .pcm
        case 3: encoding = .ieeeFloat
        default: encoding = .compressed(formatTag: tag)
        }
        return WAVFile(
            encoding: encoding,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            blockAlign: blockAlign,
            samples: includeSamples ? Data(data[range]) : Data()
        )
    }

    public func linearPCM() throws -> PCMData {
        guard encoding == .pcm else {
            throw AudioError.invalidPCMData("Expected PCM WAV, found \(encoding)")
        }
        return PCMData(
            samples: samples,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )
    }

    static func pcmHeader(
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int = 16,
        dataSize: UInt32
    ) -> Data {
        func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
            var little = value.littleEndian
            return withUnsafeBytes(of: &little) { Data($0) }
        }
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = UInt16(channels * bytesPerSample)
        let byteRate = UInt32(sampleRate * channels * bytesPerSample)
        var data = Data("RIFF".utf8)
        data.append(bytes(UInt32(36) + dataSize))
        data.append(Data("WAVEfmt ".utf8))
        data.append(bytes(UInt32(16)))
        data.append(bytes(UInt16(1)))
        data.append(bytes(UInt16(channels)))
        data.append(bytes(UInt32(sampleRate)))
        data.append(bytes(byteRate))
        data.append(bytes(blockAlign))
        data.append(bytes(UInt16(bitsPerSample)))
        data.append(Data("data".utf8))
        data.append(bytes(dataSize))
        return data
    }
}
