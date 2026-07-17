import Foundation
import XCTest
@testable import OrzAudioKit

final class WAVFileTests: XCTestCase {
    private func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)
        ]
    }

    private func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
        var result = Array(id.utf8) + le32(UInt32(payload.count)) + payload
        if payload.count.isMultiple(of: 2) == false { result.append(0) }
        return result
    }

    private func wave(_ chunks: [[UInt8]]) -> Data {
        let body = Array("WAVE".utf8) + chunks.flatMap { $0 }
        return Data(Array("RIFF".utf8) + le32(UInt32(body.count)) + body)
    }

    private func fmt(tag: UInt16 = 1, extensionBytes: [UInt8] = []) -> [UInt8] {
        le16(tag) + le16(2) + le32(44_100) + le32(176_400) +
        le16(4) + le16(16) + extensionBytes
    }

    func testWalksUnknownChunksOddPaddingAndExtendedFmt() throws {
        let samples: [UInt8] = [0, 0, 255, 127, 0, 128, 1, 0]
        let data = wave([
            chunk("JUNK", [1, 2, 3]),
            chunk("fmt ", fmt(extensionBytes: le16(0))),
            chunk("LIST", Array("metadata".utf8)),
            chunk("data", samples),
        ])

        let parsed = try WAVFile.parse(data)
        XCTAssertEqual(parsed.encoding, .pcm)
        XCTAssertEqual(parsed.sampleRate, 44_100)
        XCTAssertEqual(parsed.channels, 2)
        XCTAssertEqual(parsed.bitsPerSample, 16)
        XCTAssertEqual(parsed.samples, Data(samples))
    }

    func testClassifiesExtensibleFloatAndADPCM() throws {
        var extensible = le16(22) + le16(32) + le32(3) // cbSize, valid bits, channel mask
        extensible += le16(3) + [0, 0] // IEEE float subformat tag + GUID remainder
        extensible += [UInt8](repeating: 0, count: 12)
        let floatWAV = wave([
            chunk("fmt ", fmt(tag: 0xFFFE, extensionBytes: extensible)),
            chunk("data", [UInt8](repeating: 0, count: 8)),
        ])
        XCTAssertEqual(try WAVFile.parse(floatWAV).encoding, .ieeeFloat)

        let adpcm = wave([
            chunk("fmt ", fmt(tag: 2)),
            chunk("data", [0, 0, 0, 0]),
        ])
        XCTAssertEqual(try WAVFile.parse(adpcm).encoding, .compressed(formatTag: 2))
        XCTAssertThrowsError(try WAVFile.parse(adpcm).linearPCM())
    }

    func testRejectsTruncatedAndMisalignedData() {
        var truncated = wave([chunk("fmt ", fmt()), chunk("data", [0, 0, 0, 0])])
        truncated.removeLast()
        XCTAssertThrowsError(try WAVFile.parse(truncated))

        let misaligned = wave([chunk("fmt ", fmt()), chunk("data", [0, 0])])
        XCTAssertThrowsError(try WAVFile.parse(misaligned))
    }

    func testPCMEncoderPadsOddDataChunkAndRoundTrips() throws {
        let encoded = PCMData(
            samples: Data([0, 127, 255]), sampleRate: 8_000, channels: 1, bitsPerSample: 8
        ).encodeWAV()
        XCTAssertEqual(encoded.count, 48)
        XCTAssertEqual(try WAVFile.parse(encoded).samples, Data([0, 127, 255]))
    }

    func testAudioEngineOnlyServerDecodesCompressedWAV() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wav-strategy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pcmURL = directory.appendingPathComponent("pcm.wav")
        try PCMData(samples: Data([0, 0, 0, 0])).encodeWAV().write(to: pcmURL)
        if case .directFile = AudioEngine().resolveStreamStrategy(filePath: pcmURL.path, format: .wav) {
            // expected
        } else {
            XCTFail("PCM WAV should be sent directly to the browser")
        }

        let adpcmURL = directory.appendingPathComponent("adpcm.wav")
        let adpcm = wave([chunk("fmt ", fmt(tag: 2)), chunk("data", [0, 0, 0, 0])])
        try adpcm.write(to: adpcmURL)
        if case .serverDecode = AudioEngine().resolveStreamStrategy(filePath: adpcmURL.path, format: .wav) {
            // expected
        } else {
            XCTFail("compressed WAV should be transcoded on the server")
        }
    }

    func testStandardDecoderStreamsDirectlyToWAVFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("standard-wav-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.wav")
        let output = directory.appendingPathComponent("output.wav")
        let sourcePCM = Data(repeating: 0, count: 44_100 * 2 * 2)
        try PCMData(samples: sourcePCM).encodeWAV().write(to: input)

        try await StandardDecoder().decodeToWAVFile(
            filePath: input.path, destinationPath: output.path
        )
        let parsed = try WAVFile.parse(Data(contentsOf: output))
        XCTAssertEqual(parsed.encoding, .pcm)
        XCTAssertEqual(parsed.sampleRate, 44_100)
        XCTAssertEqual(parsed.channels, 2)
        XCTAssertEqual(parsed.samples.count, sourcePCM.count)
    }
}
