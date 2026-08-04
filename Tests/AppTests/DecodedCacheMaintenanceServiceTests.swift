import Foundation
import OrzAudioKit
import Testing
@testable import App

@Suite(.serialized) struct DecodedCacheMaintenanceServiceTests {
    private func filename(sha: Character, fingerprint: String, format: String = "sc68", subsong: Int = 0) -> String {
        "\(String(repeating: String(sha), count: 64))-\(fingerprint)-\(format)-rate-native-ch-native-sub-\(subsong).wav"
    }

    private func write(
        _ name: String,
        bytes: Int,
        modifiedAt: Date,
        directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    @Test func testReportsFingerprintsAndDryRunDeletesNothing() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orz-cache-report-\(UUID().uuidString)")
        let cache = root.appendingPathComponent(".cache/wav")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldDate = Date(timeIntervalSince1970: 100)
        let current = try write(filename(sha: "a", fingerprint: AudioDecoder.cacheFingerprint), bytes: 20, modifiedAt: oldDate, directory: cache)
        let old = try write(filename(sha: "b", fingerprint: "old-sdk"), bytes: 30, modifiedAt: oldDate, directory: cache)

        let summary = try DecodedCacheMaintenanceService(casRoot: root.path).run(
            options: .init(removeOldFingerprints: true, dryRun: true, minimumAgeSeconds: 0),
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(summary.files == 2)
        #expect(summary.totalBytes == 50)
        #expect(summary.fingerprintUsage.map(\.fingerprint) == ["old-sdk", AudioDecoder.cacheFingerprint].sorted())
        #expect(summary.selectedFiles == 1)
        #expect(summary.selectedBytes == 30)
        #expect(summary.deletedFiles == 0)
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test func testCapacityDeletesOldestEligibleFileOnlyWhenApplied() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orz-cache-capacity-\(UUID().uuidString)")
        let cache = root.appendingPathComponent(".cache/wav")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldest = try write(filename(sha: "c", fingerprint: AudioDecoder.cacheFingerprint), bytes: 40, modifiedAt: .init(timeIntervalSince1970: 100), directory: cache)
        let newest = try write(filename(sha: "d", fingerprint: AudioDecoder.cacheFingerprint), bytes: 40, modifiedAt: .init(timeIntervalSince1970: 200), directory: cache)

        let summary = try DecodedCacheMaintenanceService(casRoot: root.path).run(
            options: .init(maximumBytes: 40, dryRun: false, minimumAgeSeconds: 0),
            now: .init(timeIntervalSince1970: 1_000)
        )

        #expect(summary.deletedFiles == 1)
        #expect(summary.deletedBytes == 40)
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        #expect(FileManager.default.fileExists(atPath: newest.path))
    }

    @Test func testSharedStreamingLeaseProtectsFileFromCleanup() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orz-cache-busy-\(UUID().uuidString)")
        let cache = root.appendingPathComponent(".cache/wav")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(filename(sha: "e", fingerprint: "old-sdk"), bytes: 40, modifiedAt: .init(timeIntervalSince1970: 100), directory: cache)
        let streamLease = try DecodedCacheFileLease.acquireShared(for: file.path)
        defer { streamLease.release() }

        let summary = try DecodedCacheMaintenanceService(casRoot: root.path).run(
            options: .init(removeOldFingerprints: true, dryRun: false, minimumAgeSeconds: 0),
            now: .init(timeIntervalSince1970: 1_000)
        )

        #expect(summary.busyFiles == 1)
        #expect(summary.deletedFiles == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func testSymlinkEscapeIsRejectedWithoutTouchingExternalFile() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orz-cache-root-\(UUID().uuidString)")
        let external = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orz-cache-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external.appendingPathComponent("wav"), withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let sentinel = external.appendingPathComponent("wav/sentinel.wav")
        try Data([1]).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".cache"),
            withDestinationURL: external
        )

        #expect(throws: (any Error).self) { try DecodedCacheMaintenanceService(casRoot: root.path) }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }
}
