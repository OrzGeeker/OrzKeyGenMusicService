import FluentSQLiteDriver
import OrzAudioKit
import Vapor
import XCTest
@testable import App

final class DecodeCacheWarmupServiceTests: XCTestCase {
    private func makeApp(casRoot: String) throws -> Application {
        let app = Application(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateArtist())
        app.migrations.add(CreateAlbum())
        app.migrations.add(CreateSong())
        app.casStorage = CasStorageService(root: casRoot)
        try app.autoMigrate().wait()
        return app
    }

    private func song(id: UUID = UUID(), title: String, sha: String, format: String) -> Song {
        Song(id: id, title: title, sha256: sha, fileFormat: format, fileSize: 4)
    }

    private func createSource(for song: Song, cas: CasStorageService) throws {
        let path = cas.resolve(sha256: song.sha256, format: song.fileFormat)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0, 1, 2, 3]).write(to: URL(fileURLWithPath: path))
    }

    private func createValidCache(for song: Song, cas: CasStorageService) throws -> String {
        let directory = "\(cas.root)/.cache/wav"
        let path = DecodedAudioCacheService.cachePath(
            cacheDirectory: directory,
            sha256: song.sha256,
            format: AudioFormat(rawValue: song.fileFormat)!,
            subsong: 0
        )
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let wav = PCMData(samples: Data([0, 0, 0, 0]), sampleRate: 44_100, channels: 2).encodeWAV()
        try wav.write(to: URL(fileURLWithPath: path))
        return path
    }

    func testDryRunSelectsExplicitIDsAndNeverCreatesCache() async throws {
        let root = NSTemporaryDirectory() + "orz-warmup-dry-\(UUID().uuidString)"
        let app = try makeApp(casRoot: root)
        addTeardownBlock {
            try await app.asyncShutdown()
            try? FileManager.default.removeItem(atPath: root)
        }
        let server = song(title: "server", sha: String(repeating: "a", count: 64), format: "sc68")
        let wasm = song(title: "wasm", sha: String(repeating: "b", count: 64), format: "xm")
        try await server.create(on: app.db)
        try await wasm.create(on: app.db)
        try createSource(for: server, cas: app.casStorage)
        try createSource(for: wasm, cas: app.casStorage)

        let summary = try await DecodeCacheWarmupService(database: app.db, cas: app.casStorage)
            .run(options: .init(ids: [server.id!, wasm.id!], concurrency: 2, dryRun: true))

        XCTAssertEqual(summary.selected, 2)
        XCTAssertEqual(summary.eligible, 1)
        XCTAssertEqual(summary.skippedNonServerDecode, 1)
        XCTAssertEqual(summary.warmed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/.cache/wav"))
    }

    func testExistingCacheIsIdempotentAndUsesWebCacheSemantics() async throws {
        let root = NSTemporaryDirectory() + "orz-warmup-hit-\(UUID().uuidString)"
        let app = try makeApp(casRoot: root)
        addTeardownBlock {
            try await app.asyncShutdown()
            try? FileManager.default.removeItem(atPath: root)
        }
        let server = song(title: "cached", sha: String(repeating: "c", count: 64), format: "sc68")
        try await server.create(on: app.db)
        try createSource(for: server, cas: app.casStorage)
        let expectedPath = try createValidCache(for: server, cas: app.casStorage)
        let service = DecodeCacheWarmupService(database: app.db, cas: app.casStorage)

        let first = try await service.run(options: .init(ids: [server.id!]))
        let second = try await service.run(options: .init(ids: [server.id!]))
        let webOutcome = try await DecodedAudioCacheService(
            cas: app.casStorage,
            coordinator: DecodeCacheCoordinator()
        ).prepare(
            originalPath: app.casStorage.resolve(sha256: server.sha256, format: server.fileFormat),
            sha256: server.sha256,
            format: .sc68
        )

        XCTAssertEqual(first.cacheHits, 1)
        XCTAssertEqual(second.cacheHits, 1)
        XCTAssertEqual(first.warmed + second.warmed, 0)
        XCTAssertTrue(webOutcome.cacheHit)
        XCTAssertEqual(webOutcome.path, expectedPath)
    }

    func testFormatAndRecentSelectorsAreAppliedBeforeWarmup() async throws {
        let root = NSTemporaryDirectory() + "orz-warmup-filter-\(UUID().uuidString)"
        let app = try makeApp(casRoot: root)
        addTeardownBlock {
            try await app.asyncShutdown()
            try? FileManager.default.removeItem(atPath: root)
        }
        let older = song(title: "older", sha: String(repeating: "d", count: 64), format: "sc68")
        older.createdAt = Date(timeIntervalSince1970: 100)
        let newest = song(title: "newest", sha: String(repeating: "e", count: 64), format: "sc68")
        newest.createdAt = Date(timeIntervalSince1970: 200)
        let other = song(title: "other", sha: String(repeating: "f", count: 64), format: "xm")
        other.createdAt = Date(timeIntervalSince1970: 300)
        for item in [older, newest, other] {
            try await item.create(on: app.db)
            try createSource(for: item, cas: app.casStorage)
        }

        let summary = try await DecodeCacheWarmupService(database: app.db, cas: app.casStorage)
            .run(options: .init(format: "sc68", recent: 1, dryRun: true))

        XCTAssertEqual(summary.selected, 1)
        XCTAssertEqual(summary.eligible, 1)
        XCTAssertEqual(summary.skippedNonServerDecode, 0)
    }
}
