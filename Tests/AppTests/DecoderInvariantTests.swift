import Foundation
import XCTest
import OrzAudioKit
import OrzAudioKitCXX

final class DecoderInvariantTests: XCTestCase {
    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var messages: [String] = []
        func append(_ message: String) { lock.lock(); messages.append(message); lock.unlock() }
    }
    private func midiChunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count)
        return Array(id.utf8) + [
            UInt8(length >> 24), UInt8(length >> 16), UInt8(length >> 8), UInt8(length)
        ] + payload
    }

    private var multiTrackTempoMIDI: Data {
        let header: [UInt8] = [0x00, 0x01, 0x00, 0x02, 0x01, 0xE0] // format 1, 2 tracks, 480 PPQN
        let tempoTrack: [UInt8] = [
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, // tick 0: 500,000us
            0x83, 0x60, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40, // tick 480: 1,000,000us
            0x83, 0x60, 0xFF, 0x2F, 0x00
        ]
        let noteTrack: [UInt8] = [
            0x00, 0x90, 60, 100,               // ch 0 note on at tick 0
            0x83, 0x60, 0x91, 60, 100,         // ch 1 same note at tick 480
            0x81, 0x70, 0x80, 60, 0,           // ch 0 off at tick 720
            0x81, 0x70, 0x81, 60, 0,           // ch 1 off at tick 960
            0x00, 0xFF, 0x2F, 0x00
        ]
        return Data(midiChunk("MThd", header) + midiChunk("MTrk", tempoTrack) + midiChunk("MTrk", noteTrack))
    }

    private func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)
        ]
    }

    private func ym6Data(interleaved: Bool) -> Data {
        let frames: [[UInt8]] = (0..<4).map { index in
            var registers = [UInt8](repeating: 0, count: 16)
            registers[0] = UInt8(125 + index)
            registers[7] = 0x38 // tone enabled, noise disabled
            registers[8] = 15
            registers[9] = 10
            registers[10] = 5
            registers[13] = index == 0 ? 0x09 : 0xFF
            return registers
        }
        var bytes = Array("YM6!LeOnArD!".utf8)
        bytes += be32(UInt32(frames.count))
        bytes += be32(interleaved ? 1 : 0)
        bytes += be16(1) // one digidrum exercises variable header skipping
        bytes += be32(2_000_000)
        bytes += be16(50)
        bytes += be32(0)
        bytes += be16(2) + [0xAA, 0x55] // extra data
        bytes += be32(3) + [1, 2, 3] // digidrum payload
        bytes += Array("test\0author\0comment\0".utf8)
        if interleaved {
            for register in 0..<16 {
                for frame in frames { bytes.append(frame[register]) }
            }
        } else {
            for frame in frames { bytes += frame }
        }
        return Data(bytes)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    private func render(
        relativePath: String,
        format: String,
        chunkFrames: Int,
        limitFrames: Int
    ) throws -> [Float] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
        return try render(data: data, format: format, chunkFrames: chunkFrames, limitFrames: limitFrames)
    }

    private func render(
        data: Data,
        format: String,
        chunkFrames: Int,
        limitFrames: Int
    ) throws -> [Float] {
        let loaded = data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return Int32(0) }
            return format.withCString { cFormat in
                orz_load(
                    cFormat,
                    baseAddress.assumingMemoryBound(to: UInt8.self),
                    Int32(bytes.count)
                )
            }
        }
        XCTAssertNotEqual(loaded, 0, "Failed to load \(format) data")
        guard loaded != 0 else { return [] }
        defer { orz_destroy() }

        let channels = Int(orz_get_channels())
        XCTAssertGreaterThan(channels, 0)
        var result: [Float] = []
        result.reserveCapacity(limitFrames * channels)
        var renderedFrames = 0

        while renderedFrames < limitFrames {
            let request = min(chunkFrames, limitFrames - renderedFrames)
            var buffer = [Float](repeating: 0, count: request * channels)
            let rendered = Int(orz_render(&buffer, Int32(request)))
            if rendered <= 0 { break }
            result.append(contentsOf: buffer.prefix(rendered * channels))
            renderedFrames += rendered
        }
        return result
    }

    private func assertChunkInvariant(
        relativePath: String,
        format: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let frames = format == "mod" ? 48_000 : 44_100
        let small = try render(
            relativePath: relativePath,
            format: format,
            chunkFrames: 127,
            limitFrames: frames
        )
        let large = try render(
            relativePath: relativePath,
            format: format,
            chunkFrames: 4096,
            limitFrames: frames
        )

        XCTAssertEqual(small.count, large.count, file: file, line: line)
        guard small.count == large.count else { return }
        let accuracy: Float = 1e-6
        let maxDifference = zip(small, large).reduce(Float.zero) {
            max($0, abs($1.0 - $1.1))
        }
        let firstDifference = zip(small, large).enumerated().first {
            abs($0.element.0 - $0.element.1) > accuracy
        }
        XCTAssertLessThanOrEqual(
            maxDifference,
            accuracy,
            "first difference: \(String(describing: firstDifference))",
            file: file,
            line: line
        )
    }

    private func decoderDuration(relativePath: String, format: String) throws -> Double {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
        let loaded = data.withUnsafeBytes { bytes in
            format.withCString {
                orz_load($0, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(bytes.count))
            }
        }
        XCTAssertNotEqual(loaded, 0)
        guard loaded != 0 else { return 0 }
        defer { orz_destroy() }
        return orz_get_duration()
    }

    private func assertIndependentHandles(
        data: Data,
        format: String,
        frames: Int = 257,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pair = data.withUnsafeBytes { bytes in
            format.withCString { name in
                (
                    orz_decoder_create(name, bytes.baseAddress, Int32(bytes.count)),
                    orz_decoder_create(name, bytes.baseAddress, Int32(bytes.count))
                )
            }
        }
        guard let first = pair.0, let second = pair.1 else {
            if let first = pair.0 { orz_decoder_destroy(first) }
            if let second = pair.1 { orz_decoder_destroy(second) }
            XCTFail("\(format) did not create two live handles (first=\(pair.0 != nil), second=\(pair.1 != nil))", file: file, line: line)
            return
        }
        defer { orz_decoder_destroy(first); orz_decoder_destroy(second) }
        XCTAssertEqual(orz_decoder_get_channels(first), 2, file: file, line: line)
        var a = [Float](repeating: 0, count: frames * 2)
        var b = [Float](repeating: 0, count: frames * 2)
        XCTAssertEqual(orz_decoder_render(first, &a, Int32(frames)), Int32(frames), file: file, line: line)
        XCTAssertEqual(orz_decoder_render(second, &b, Int32(frames)), Int32(frames), file: file, line: line)
        XCTAssertEqual(a, b, "\(format) initial blocks differ", file: file, line: line)
        var advanceA = [Float](repeating: 0, count: 113 * 2)
        var advanceB = [Float](repeating: 0, count: 113 * 2)
        _ = orz_decoder_render(first, &advanceA, 113)
        _ = orz_decoder_render(second, &advanceB, 113)
        XCTAssertEqual(advanceA, advanceB, "\(format) cursors are not independent", file: file, line: line)
    }

    func testAllDecoderBackendsSupportTwoLiveHandles() throws {
        let samples: [(String, String)] = [
            ("mod", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/MP2K/MP2K - UltraEdit11.x crk.mod"),
            ("nsf", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/Kindly/Kindly - PowerISO 6.2.0.0 crk.nsf"),
            ("sap", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/TorbyTorrents/TorbyTorrents - 8BitBoy intro.sap"),
            ("sid", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/HYBRiD/HYBRiD - Astro Fire intro.sid"),
            ("v2m", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/RESURRECTiON/RESURRECTiON - PowerCHM 5.x kg.v2m"),
            ("rad", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/TorbyTorrents/TorbyTorrents - Rune Gold trn.rad"),
            ("sc68", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/LEGEND/LEGEND - Dynamite Dick intro_1.sc68"),
            ("ahx", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/Under SEH/Under SEH - MP3 Splitter Joiner Pro 3.9b2398 crk.ahx"),
            ("bp", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/EDGE/EDGE - SPSS 16.0 kg.bp")
        ]
        for (format, path) in samples {
            assertIndependentHandles(data: try Data(contentsOf: repositoryRoot.appendingPathComponent(path)), format: format)
        }
        assertIndependentHandles(data: ym6Data(interleaved: true), format: "ym")
        assertIndependentHandles(data: multiTrackTempoMIDI, format: "mid")
    }

    private static func firstHandleBlock(data: Data, format: String, frames: Int = 512) throws -> [Float] {
        let decoder = data.withUnsafeBytes { bytes in
            format.withCString { orz_decoder_create($0, bytes.baseAddress, Int32(bytes.count)) }
        }
        guard let decoder else { throw NSError(domain: "decoder", code: 1) }
        defer { orz_decoder_destroy(decoder) }
        var pcm = [Float](repeating: 0, count: frames * 2)
        guard orz_decoder_render(decoder, &pcm, Int32(frames)) == frames else {
            throw NSError(domain: "decoder", code: 2)
        }
        return pcm
    }

    func testDecoderHandlesRenderConcurrentlyWithoutCrossTalk() throws {
        let inputs: [(String, Data)] = [
            ("mod", try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/MP2K/MP2K - UltraEdit11.x crk.mod"))),
            ("nsf", try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/Kindly/Kindly - PowerISO 6.2.0.0 crk.nsf"))),
            ("sap", try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/TorbyTorrents/TorbyTorrents - 8BitBoy intro.sap"))),
            ("sid", try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/HYBRiD/HYBRiD - Astro Fire intro.sid"))),
            ("rad", try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/TorbyTorrents/TorbyTorrents - Rune Gold trn.rad"))),
            ("ahx", try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/Under SEH/Under SEH - MP3 Splitter Joiner Pro 3.9b2398 crk.ahx"))),
            ("ym", ym6Data(interleaved: true)),
            ("mid", multiTrackTempoMIDI)
        ]
        let expected = try Dictionary(uniqueKeysWithValues: inputs.map { ($0.0, try Self.firstHandleBlock(data: $0.1, format: $0.0)) })
        let failures = FailureBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "decoder.parallel.test", attributes: .concurrent)
        for iteration in 0..<4 {
            for (format, data) in inputs {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    do {
                        let actual = try DecoderInvariantTests.firstHandleBlock(data: data, format: format)
                        if actual != expected[format] { failures.append("\(format) mismatch at iteration \(iteration)") }
                    } catch { failures.append("\(format) failed at iteration \(iteration): \(error)") }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "\n"))
    }

    func testSwiftBridgeDecodesInParallelWithoutGlobalSerialization() throws {
        let data = ym6Data(interleaved: true)
        let expected = try CDecoderBridge.decode(fileData: data, format: "ym")
        let failures = FailureBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "decoder.swift.bridge.parallel.test", attributes: .concurrent)

        for iteration in 0..<12 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let actual = try CDecoderBridge.decode(fileData: data, format: "ym")
                    if actual.samples != expected.samples ||
                        actual.sampleRate != expected.sampleRate ||
                        actual.channels != expected.channels {
                        failures.append("Swift bridge mismatch at iteration \(iteration)")
                    }
                } catch {
                    failures.append("Swift bridge failed at iteration \(iteration): \(error)")
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "\n"))
    }

    func testBPUsesDedicatedSoundMonDecoder() {
        XCTAssertEqual("bp".withCString { orz_can_decode($0) }, 1)
    }

    func testBPRealSamplesLoadRenderAndAreChunkInvariant() throws {
        let paths = [
            "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/EDGE/EDGE - SPSS 16.0 kg.bp",
            "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/EDGE/EDGE - Symantec Norton Antibot 1.0 kg.bp",
            "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/EDGE/EDGE - viewnowx 9.6.1 kg.bp",
            "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/!Others/TOED - Flatout 2 intro.bp"
        ]

        for path in paths {
            let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(path))
            let smallChunks = try render(data: data, format: "bp", chunkFrames: 127, limitFrames: 132_300)
            let largeChunks = try render(data: data, format: "bp", chunkFrames: 4_096, limitFrames: 132_300)
            XCTAssertEqual(smallChunks, largeChunks, "Chunk-dependent output for \(path)")
            XCTAssertTrue(smallChunks.contains { abs($0) > 0.0001 }, "Silent BP output for \(path)")
        }
    }

    func testBPRejectsMalformedSectionBoundaries() throws {
        let path = "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/EDGE/EDGE - SPSS 16.0 kg.bp"
        let source = try Data(contentsOf: repositoryRoot.appendingPathComponent(path))
        let steps = Int(source[30]) << 8 | Int(source[31])
        let sequenceEnd = 512 + steps * 16
        var highestPattern = 0
        for offset in stride(from: 512, to: sequenceEnd, by: 4) {
            highestPattern = max(highestPattern, Int(source[offset]) << 8 | Int(source[offset + 1]))
        }
        let patternEnd = sequenceEnd + highestPattern * 48
        let tableEnd = patternEnd + Int(source[29]) * 64

        for boundary in [0, 31, 511, sequenceEnd - 1, patternEnd - 1, tableEnd - 1, source.count - 1] {
            let truncated = source.prefix(boundary)
            let decoder = truncated.withUnsafeBytes { bytes in
                "bp".withCString { orz_decoder_create($0, bytes.baseAddress, Int32(bytes.count)) }
            }
            XCTAssertNil(decoder, "Accepted BP truncation at \(boundary)")
            if let decoder { orz_decoder_destroy(decoder) }
        }

        var invalidPattern = source
        invalidPattern[512] = 0
        invalidPattern[513] = 0
        let decoder = invalidPattern.withUnsafeBytes { bytes in
            "bp".withCString { orz_decoder_create($0, bytes.baseAddress, Int32(bytes.count)) }
        }
        XCTAssertNil(decoder)
        if let decoder { orz_decoder_destroy(decoder) }
    }

    func testAllDecodersRejectTinyTruncatedAndOversizedInputs() throws {
        let samples: [(String, String)] = [
            ("mod", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/MP2K/MP2K - UltraEdit11.x crk.mod"),
            ("nsf", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/Kindly/Kindly - PowerISO 6.2.0.0 crk.nsf"),
            ("sap", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/TorbyTorrents/TorbyTorrents - 8BitBoy intro.sap"),
            ("sid", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/HYBRiD/HYBRiD - Astro Fire intro.sid"),
            ("v2m", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/RESURRECTiON/RESURRECTiON - PowerCHM 5.x kg.v2m"),
            ("rad", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/TorbyTorrents/TorbyTorrents - Rune Gold trn.rad"),
            ("sc68", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/LEGEND/LEGEND - Dynamite Dick intro_1.sc68"),
            ("ahx", "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/Under SEH/Under SEH - MP3 Splitter Joiner Pro 3.9b2398 crk.ahx")
        ]

        for (format, path) in samples {
            let source = try Data(contentsOf: repositoryRoot.appendingPathComponent(path))
            for length in 1...min(16, source.count) {
                let truncated = source.prefix(length)
                let decoder = truncated.withUnsafeBytes { bytes in
                    format.withCString { orz_decoder_create($0, bytes.baseAddress, Int32(bytes.count)) }
                }
                if let decoder { orz_decoder_destroy(decoder) }
                XCTAssertNil(decoder, "\(format) accepted a \(length)-byte prefix")
            }
        }

        var byte: UInt8 = 0
        let oversized = withUnsafePointer(to: &byte) { pointer in
            "mid".withCString { orz_decoder_create($0, pointer, 512 * 1024 * 1024 + 1) }
        }
        XCTAssertNil(oversized)
    }

    func testRenderRejectsOverflowingFrameCount() {
        let data = ym6Data(interleaved: true)
        let decoder = data.withUnsafeBytes { bytes in
            "ym".withCString { orz_decoder_create($0, bytes.baseAddress, Int32(bytes.count)) }
        }
        guard let decoder else { return XCTFail("YM fixture failed to load") }
        defer { orz_decoder_destroy(decoder) }
        var sample: Float = 0
        XCTAssertEqual(orz_decoder_render(decoder, &sample, Int32.max), 0)
        XCTAssertEqual(orz_decoder_render(decoder, &sample, 0), 0)
        XCTAssertEqual(orz_decoder_render(decoder, &sample, -1), 0)
    }

    func testOpenMPTIsChunkInvariant() throws {
        try assertChunkInvariant(
            relativePath: "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/MP2K/MP2K - UltraEdit11.x crk.mod",
            format: "mod"
        )
    }

    func testOpenMPTSupportsIndependentDecoderHandles() throws {
        let url = repositoryRoot.appendingPathComponent(
            "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/MP2K/MP2K - UltraEdit11.x crk.mod"
        )
        let data = try Data(contentsOf: url)
        let handles = data.withUnsafeBytes { bytes in
            "mod".withCString { format in
                (
                    orz_decoder_create(format, bytes.baseAddress, Int32(bytes.count)),
                    orz_decoder_create(format, bytes.baseAddress, Int32(bytes.count))
                )
            }
        }
        guard let first = handles.0, let second = handles.1 else {
            XCTFail("OpenMPT must create two simultaneous decoder instances")
            if let first = handles.0 { orz_decoder_destroy(first) }
            if let second = handles.1 { orz_decoder_destroy(second) }
            return
        }
        defer {
            orz_decoder_destroy(first)
            orz_decoder_destroy(second)
        }

        XCTAssertEqual(orz_decoder_get_sample_rate(first), 48_000)
        XCTAssertEqual(orz_decoder_get_channels(first), 2)
        XCTAssertGreaterThan(orz_decoder_get_duration(first), 0)

        var firstBlock = [Float](repeating: 0, count: 257 * 2)
        var secondBlock = [Float](repeating: 0, count: 257 * 2)
        XCTAssertEqual(orz_decoder_render(first, &firstBlock, 257), 257)
        XCTAssertEqual(orz_decoder_render(second, &secondBlock, 257), 257)
        XCTAssertEqual(firstBlock, secondBlock)

        // Advancing one instance must not move the other instance's cursor.
        var discarded = [Float](repeating: 0, count: 113 * 2)
        XCTAssertEqual(orz_decoder_render(first, &discarded, 113), 113)
        var secondNext = [Float](repeating: 0, count: 113 * 2)
        XCTAssertEqual(orz_decoder_render(second, &secondNext, 113), 113)
        XCTAssertEqual(discarded, secondNext)
    }

    func testOpenMPTSubsongAndSeekNavigation() throws {
        let path = "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/MP2K/MP2K - UltraEdit11.x crk.mod"
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(path))
        let decoder = data.withUnsafeBytes { bytes in
            "mod".withCString { orz_decoder_create($0, bytes.baseAddress, Int32(bytes.count)) }
        }
        let handle = try XCTUnwrap(decoder)
        defer { orz_decoder_destroy(handle) }
        let count = orz_decoder_get_subsong_count(handle)
        XCTAssertGreaterThanOrEqual(count, 1)
        XCTAssertEqual(orz_decoder_select_subsong(handle, 0), 0)
        XCTAssertNotEqual(orz_decoder_select_subsong(handle, count), 0)
        XCTAssertEqual(orz_decoder_seek_ms(handle, 1_000), 0)
        var pcm = [Float](repeating: 0, count: 512 * 2)
        XCTAssertEqual(orz_decoder_render(handle, &pcm, 512), 512)
        XCTAssertTrue(pcm.contains { abs($0) > 0.0001 })
    }

    func testASAPIsChunkInvariant() throws {
        try assertChunkInvariant(
            relativePath: "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/TorbyTorrents/TorbyTorrents - 8BitBoy intro.sap",
            format: "sap"
        )
    }

    func testAdPlugIsChunkInvariant() throws {
        try assertChunkInvariant(
            relativePath: "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/TorbyTorrents/TorbyTorrents - Rune Gold trn.rad",
            format: "rad"
        )
    }

    func testAHXIsChunkInvariantAcrossReloads() throws {
        try assertChunkInvariant(
            relativePath: "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/Under SEH/Under SEH - MP3 Splitter Joiner Pro 3.9b2398 crk.ahx",
            format: "ahx"
        )
    }

    func testMIDIMultiTrackTempoMapAndChunkInvariant() throws {
        let data = multiTrackTempoMIDI
        let loaded = data.withUnsafeBytes { bytes in
            "mid".withCString {
                orz_load($0, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(bytes.count))
            }
        }
        XCTAssertNotEqual(loaded, 0)
        XCTAssertEqual(orz_get_duration(), 1.8, accuracy: 0.000_001)
        orz_destroy()

        let small = try render(data: data, format: "mid", chunkFrames: 127, limitFrames: 80_000)
        let large = try render(data: data, format: "mid", chunkFrames: 4096, limitFrames: 80_000)
        XCTAssertEqual(small.count, large.count)
        XCTAssertEqual(zip(small, large).map { abs($0.0 - $0.1) }.max() ?? 0, 0, accuracy: 1e-7)
        XCTAssertTrue(small.contains { abs($0) > 0.001 })
    }

    func testMIDIRejectsTruncatedVLQ() {
        let header: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x01, 0xE0]
        let malformed = Data(midiChunk("MThd", header) + midiChunk("MTrk", [0x80]))
        let loaded = malformed.withUnsafeBytes { bytes in
            "mid".withCString {
                orz_load($0, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(bytes.count))
            }
        }
        XCTAssertEqual(loaded, 0)
    }

    func testYM6LayoutsDurationAndChunkInvariant() throws {
        let interleaved = ym6Data(interleaved: true)
        let frameMajor = ym6Data(interleaved: false)

        let loaded = interleaved.withUnsafeBytes { bytes in
            "ym".withCString {
                orz_load($0, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(bytes.count))
            }
        }
        XCTAssertNotEqual(loaded, 0)
        XCTAssertEqual(orz_get_duration(), 0.08, accuracy: 0.000_001)
        orz_destroy()

        let a = try render(data: interleaved, format: "ym", chunkFrames: 127, limitFrames: 3_528)
        let b = try render(data: interleaved, format: "ym", chunkFrames: 2_000, limitFrames: 3_528)
        let c = try render(data: frameMajor, format: "ym", chunkFrames: 127, limitFrames: 3_528)
        XCTAssertEqual(a.count, 7_056)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
        XCTAssertTrue(a.contains { abs($0) > 0.01 })
    }

    func testYM6RejectsTruncatedMetadata() {
        var bytes = Array("YM6!LeOnArD!".utf8)
        bytes += be32(1) + be32(1) + be16(0) + be32(2_000_000)
        bytes += be16(50) + be32(0) + be16(0)
        bytes += Array("unterminated".utf8)
        let data = Data(bytes)
        let loaded = data.withUnsafeBytes { raw in
            "ym".withCString {
                orz_load($0, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(raw.count))
            }
        }
        XCTAssertEqual(loaded, 0)
    }

    func testYMCompressedRealSampleLoadsAndRenders() throws {
        let relativePath = "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/Solitary/Solitary - PDF Explorer crk.ym"
        let pcm = try render(relativePath: relativePath, format: "ym", chunkFrames: 127, limitFrames: 44_100)
        XCTAssertEqual(pcm.count, 88_200)
        XCTAssertTrue(pcm.contains { abs($0) > 0.01 })
    }

    func testYMZeroPeriodRegisterDoesNotHang() throws {
        let relativePath = "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/Solitary/Solitary - Extra Drive Creator Pro 7.2 kg.ym"
        let pcm = try render(relativePath: relativePath, format: "ym", chunkFrames: 2_048, limitFrames: 44_100)
        XCTAssertEqual(pcm.count, 88_200)
        XCTAssertTrue(pcm.allSatisfy(\.isFinite))
        XCTAssertTrue(pcm.contains { abs($0) > 0.01 })
    }

    func testYMCompressedChessTigerLoadsAndRenders() throws {
        let relativePath = "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/EDGE/EDGE - ChessTiger 2007 UCI kg.ym"
        let pcm = try render(relativePath: relativePath, format: "ym", chunkFrames: 2_048, limitFrames: 44_100)
        XCTAssertEqual(pcm.count, 88_200)
        XCTAssertTrue(pcm.allSatisfy(\.isFinite))
        XCTAssertTrue(pcm.contains { abs($0) > 0.01 })
    }

    func testGMEFormatsAreChunkInvariantAndHaveFinitePolicy() throws {
        let nsf = "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/Kindly/Kindly - PowerISO 6.2.0.0 crk.nsf"
        let spc = "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/FFF/FFF - Alcohol 120% 1.9.8.7507 kg.spc"
        try assertChunkInvariant(relativePath: nsf, format: "nsf")
        try assertChunkInvariant(relativePath: spc, format: "spc")
        XCTAssertGreaterThan(try decoderDuration(relativePath: nsf, format: "nsf"), 0)
        XCTAssertGreaterThan(try decoderDuration(relativePath: spc, format: "spc"), 0)
    }

    func testSIDFractionalClockIsChunkInvariant() throws {
        let sid = "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/HYBRiD/HYBRiD - Astro Fire intro.sid"
        try assertChunkInvariant(relativePath: sid, format: "sid")
        XCTAssertEqual(try decoderDuration(relativePath: sid, format: "sid"), 180, accuracy: 0.001)
    }

    func testV2MUsesPlayerLengthAndIsChunkInvariant() throws {
        let v2m = "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/RESURRECTiON/RESURRECTiON - PowerCHM 5.x kg.v2m"
        let duration = try decoderDuration(relativePath: v2m, format: "v2m")
        XCTAssertEqual(duration, 195, accuracy: 0.001, "V2MPlayer::Length is measured in seconds")
        XCTAssertNotEqual(duration, 120, "must not use the former file-size heuristic")
        try assertChunkInvariant(relativePath: v2m, format: "v2m")
    }

    func testV2MDoesNotStopBeforeFirstAudibleNote() throws {
        let v2m = "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/iOTA/iOTA - ACDSee Pro 5.3 build 168 crk.v2m"
        let pcm = try render(relativePath: v2m, format: "v2m", chunkFrames: 2_048, limitFrames: 44_100)
        XCTAssertEqual(pcm.count, 88_200)
        XCTAssertTrue(pcm.allSatisfy(\.isFinite))
        XCTAssertTrue(pcm.contains { abs($0) > 0.01 }, "V2M output remained silent")
    }

    func testV2MConvertsHistoricalSynthLayoutsBeforePlayback() throws {
        let samples = [
            "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/kZ/kZ - DeskSoft HardCopy Pro 3.2.1 crk.v2m",
            "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/DimitarSerg/DimitarSerg - Resource Builder 3.0.3.25 kg.v2m"
        ]
        for sample in samples {
            let pcm = try render(relativePath: sample, format: "v2m", chunkFrames: 2_048, limitFrames: 5 * 44_100)
            XCTAssertEqual(pcm.count, 10 * 44_100, "Unexpected early end: \(sample)")
            XCTAssertTrue(pcm.allSatisfy(\.isFinite), "Non-finite V2M output: \(sample)")
            XCTAssertTrue(pcm.contains { abs($0) > 0.01 }, "Historical V2M remained silent: \(sample)")
        }
    }

    func testSC68AmigaPaulaProducesAudio() throws {
        let sc68 = "Resources/Public/keygenmusic/KEYGENMUSiC MusicPack/LEGEND/LEGEND - Dynamite Dick intro_1.sc68"
        let pcm = try render(relativePath: sc68, format: "sc68", chunkFrames: 2_048, limitFrames: 88_200)
        XCTAssertEqual(pcm.count, 176_400)
        XCTAssertTrue(pcm.allSatisfy(\.isFinite))
        XCTAssertTrue(pcm.contains { abs($0) > 0.01 }, "SC68 Paula output remained silent")
    }

    func testCDecoderStreamsWAVToDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdecoder-wav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("input.ym")
        let output = directory.appendingPathComponent("output.wav")
        try ym6Data(interleaved: true).write(to: input)
        try CDecoderBridge.decodeToWAVFile(
            filePath: input.path,
            format: "ym",
            destinationPath: output.path
        )
        // Replacing an existing cache entry must also use the finalized file.
        try CDecoderBridge.decodeToWAVFile(
            filePath: input.path,
            format: "ym",
            destinationPath: output.path
        )

        let wav = try WAVFile.parse(Data(contentsOf: output))
        XCTAssertEqual(wav.encoding, .pcm)
        XCTAssertEqual(wav.sampleRate, 44_100)
        XCTAssertEqual(wav.channels, 2)
        XCTAssertEqual(wav.bitsPerSample, 16)
        XCTAssertEqual(wav.samples.count, 3_528 * 2 * 2)
        XCTAssertTrue(wav.samples.contains { $0 != 0 })
    }

    func testCDecoderStreamingFailureLeavesNoDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdecoder-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("bad.ym")
        let output = directory.appendingPathComponent("bad.wav")
        try Data([0, 1, 2]).write(to: input)

        XCTAssertThrowsError(try CDecoderBridge.decodeToWAVFile(
            filePath: input.path,
            format: "ym",
            destinationPath: output.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

}
