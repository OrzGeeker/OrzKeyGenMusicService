@testable import App
@testable import OrzAudioKit
import XCTVapor
import Fluent
import FluentSQL
import FluentSQLiteDriver

final class AppTests: XCTestCase {

    private struct AdminAPIErrorResponse: Content {
        let error: String
        let reason: String
        let code: Int
    }

    // MARK: - Test Lifecycle

    private func createTestApp() throws -> Application {
        let app = Application(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.adminAPIToken = "test-admin-token"

        // Register migrations
        app.migrations.add(CreateArtist())
        app.migrations.add(CreateAlbum())
        app.migrations.add(CreateSong())
        app.migrations.add(CreateSongListIndexes())
        app.migrations.add(CreateSearchTrigramIndexes())
        app.migrations.add(CreatePlaylist())
        app.migrations.add(CreatePlaylistSongPivot())

        // Register routes (without static file middleware)
        try routes(app)

        // Configure CAS storage for test
        app.casStorage = CasStorageService(root: NSTemporaryDirectory() + "cas-test-\(UUID().uuidString)")

        // Run migrations
        try app.autoMigrate().wait()

        return app
    }

    private func createAsyncTestApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.adminAPIToken = "test-admin-token"
        app.migrations.add(CreateArtist())
        app.migrations.add(CreateAlbum())
        app.migrations.add(CreateSong())
        app.migrations.add(CreateSongListIndexes())
        app.migrations.add(CreateSearchTrigramIndexes())
        app.migrations.add(CreatePlaylist())
        app.migrations.add(CreatePlaylistSongPivot())
        try routes(app)
        app.casStorage = CasStorageService(root: NSTemporaryDirectory() + "cas-test-\(UUID().uuidString)")
        try await app.autoMigrate()
        return app
    }

    /// Helper: encode a JSON object to ByteBuffer
    private func jsonBuffer(_ value: some Encodable) -> ByteBuffer {
        let data = try! JSONEncoder().encode(value)
        return ByteBuffer(data: data)
    }

    /// Stable UUIDs keep `id DESC` test ordering deterministic when SQLite
    /// timestamps multiple inserts within the same second.
    private func orderedUUID(_ value: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", value))")!
    }

    // MARK: - OrzAudioKit Unit Tests

    func testAudioFormatDetection() {
        // All supported formats
        XCTAssertNotNil(AudioFormat.from(fileExtension: "xm"))
        XCTAssertNotNil(AudioFormat.from(fileExtension: "mod"))
        XCTAssertNotNil(AudioFormat.from(fileExtension: "it"))
        XCTAssertNotNil(AudioFormat.from(fileExtension: "s3m"))
        XCTAssertNotNil(AudioFormat.from(fileExtension: "mp3"))
        XCTAssertNotNil(AudioFormat.from(fileExtension: "ogg"))
        XCTAssertNotNil(AudioFormat.from(fileExtension: "wav"))
        XCTAssertNotNil(AudioFormat.from(fileExtension: "flac"))
        XCTAssertNotNil(AudioFormat.from(fileExtension: "sid"))
        XCTAssertNotNil(AudioFormat.from(fileExtension: "nsf"))
        XCTAssertNotNil(AudioFormat.from(fileExtension: "spc"))
        XCTAssertNotNil(AudioFormat.from(fileExtension: "v2m"))

        // Unknown format
        XCTAssertNil(AudioFormat.from(fileExtension: "unknown"))
        XCTAssertNil(AudioFormat.from(fileExtension: "txt"))
        XCTAssertNil(AudioFormat.from(fileExtension: "pdf"))
    }

    func testPlayStrategy() {
        // directFile formats
        XCTAssertEqual(AudioFormat.from(fileExtension: "mp3")?.playStrategy.rawValue, "directFile")
        XCTAssertEqual(AudioFormat.from(fileExtension: "ogg")?.playStrategy.rawValue, "directFile")
        XCTAssertEqual(AudioFormat.from(fileExtension: "flac")?.playStrategy.rawValue, "directFile")
        XCTAssertEqual(AudioFormat.from(fileExtension: "mid")?.playStrategy.rawValue, "wasmDecode")

        // wasmDecode formats
        XCTAssertEqual(AudioFormat.from(fileExtension: "xm")?.playStrategy.rawValue, "wasmDecode")
        XCTAssertEqual(AudioFormat.from(fileExtension: "mod")?.playStrategy.rawValue, "wasmDecode")
        XCTAssertEqual(AudioFormat.from(fileExtension: "it")?.playStrategy.rawValue, "wasmDecode")
        XCTAssertEqual(AudioFormat.from(fileExtension: "s3m")?.playStrategy.rawValue, "wasmDecode")
        XCTAssertEqual(AudioFormat.from(fileExtension: "sid")?.playStrategy.rawValue, "wasmDecode")
        XCTAssertEqual(AudioFormat.from(fileExtension: "nsf")?.playStrategy.rawValue, "wasmDecode")
        XCTAssertEqual(AudioFormat.from(fileExtension: "bp")?.playStrategy.rawValue, "wasmDecode")

        // serverDecode formats (WAV may have ADPCM/GSM encoding, needs ffmpeg)
        XCTAssertEqual(AudioFormat.from(fileExtension: "wav")?.playStrategy.rawValue, "serverDecode")
    }

    func testPCMEncodeWAV() {
        let pcm = PCMData(samples: Data([0x00, 0x00, 0xFF, 0x7F]))
        let wav = pcm.encodeWAV()

        // WAV header: "RIFF" at start
        XCTAssertEqual(String(data: wav[0..<4], encoding: .utf8), "RIFF")
        // WAV format: "WAVE"
        XCTAssertEqual(String(data: wav[8..<12], encoding: .utf8), "WAVE")
        // fmt chunk
        XCTAssertEqual(String(data: wav[12..<16], encoding: .utf8), "fmt ")
        // data chunk
        XCTAssertEqual(String(data: wav[36..<40], encoding: .utf8), "data")

        // Total header is 44 bytes, data follows
        XCTAssertEqual(wav.count, 44 + 4) // header + 4 bytes of sample data
    }

    func testPCMEncodeWAVEmptySamples() {
        let pcm = PCMData()
        let wav = pcm.encodeWAV()
        // Valid header even with no samples
        XCTAssertEqual(String(data: wav[0..<4], encoding: .utf8), "RIFF")
        XCTAssertEqual(wav.count, 44) // header only
    }

    func testAudioEngineResolveStreamStrategy() {
        let engine = AudioEngine()

        // directFile
        let mp3Strategy = engine.resolveStreamStrategy(filePath: "/test.mp3", format: .mp3)
        if case .directFile(let path, let mime) = mp3Strategy {
            XCTAssertEqual(path, "/test.mp3")
            XCTAssertEqual(mime, "audio/mpeg")
        } else {
            XCTFail("Expected directFile strategy for mp3")
        }

        // wasmDecode
        let xmStrategy = engine.resolveStreamStrategy(filePath: "/test.xm", format: .xm)
        if case .wasmDecode(let path, let fmt) = xmStrategy {
            XCTAssertEqual(path, "/test.xm")
            XCTAssertEqual(fmt, .xm)
        } else {
            XCTFail("Expected wasmDecode strategy for xm")
        }

        // SoundMon BP is decoded by the shared native/WASM C decoder.
        let bpStrategy = engine.resolveStreamStrategy(filePath: "/test.bp", format: .bp)
        if case .wasmDecode(let path, let fmt) = bpStrategy {
            XCTAssertEqual(path, "/test.bp")
            XCTAssertEqual(fmt, .bp)
        } else {
            XCTFail("Expected wasmDecode strategy for bp")
        }
    }

    func testAudioFormatMimeTypes() {
        XCTAssertEqual(AudioFormat.mp3.mimeType, "audio/mpeg")
        XCTAssertEqual(AudioFormat.ogg.mimeType, "audio/ogg")
        XCTAssertEqual(AudioFormat.wav.mimeType, "audio/wav")
        XCTAssertEqual(AudioFormat.flac.mimeType, "audio/flac")
        XCTAssertEqual(AudioFormat.mid.mimeType, "audio/midi")
        XCTAssertEqual(AudioFormat.xm.mimeType, "audio/x-mod")
        XCTAssertEqual(AudioFormat.sid.mimeType, "application/octet-stream")
    }

    // MARK: - API Integration Tests

    func testStatsEndpoint() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        try app.test(.GET, "/api/stats") { res in
            XCTAssertEqual(res.status, .ok)
            let stats = try res.content.decode(StatsResponse.self)
            XCTAssertEqual(stats.totalSongs, 0)
            XCTAssertEqual(stats.totalArtists, 0)
            XCTAssertEqual(stats.totalAlbums, 0)
            XCTAssertEqual(stats.totalPlaylists, 0)
        }
    }

    func testEmptySongsList() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        try app.test(.GET, "/api/songs") { res in
            XCTAssertEqual(res.status, .ok)
            let page = try res.content.decode(Page<SongResponse>.self)
            XCTAssertEqual(page.items.count, 0)
            XCTAssertEqual(page.metadata.total, 0)
        }
    }

    func testAdministrativeEndpointsRequireConfiguredBearerToken() throws {
        let disabledApp = Application(.testing)
        defer { disabledApp.shutdown() }
        disabledApp.databases.use(.sqlite(.memory), as: .sqlite)
        disabledApp.adminAPIToken = nil
        disabledApp.casStorage = CasStorageService(root: NSTemporaryDirectory() + "cas-test-\(UUID().uuidString)")
        try routes(disabledApp)

        try disabledApp.test(.POST, "/api/scan") { response in
            XCTAssertEqual(response.status, .serviceUnavailable)
            let body = try response.content.decode(AdminAPIErrorResponse.self)
            XCTAssertEqual(body.error, "admin_api_disabled")
        }

        let app = try createTestApp()
        defer { app.shutdown() }

        try app.test(.POST, "/api/upload") { response in
            XCTAssertEqual(response.status, .unauthorized)
        }

        try app.test(.POST, "/api/upload", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
        }) { response in
            XCTAssertNotEqual(response.status, .unauthorized, "A valid token must reach the controller")
        }

        try app.test(.DELETE, "/api/songs/\(UUID())", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .authorization, value: "Bearer wrong-token")
        }) { response in
            XCTAssertEqual(response.status, .unauthorized)
        }

        try app.test(.POST, "/api/scan", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
            request.headers.contentType = .json
            request.body = jsonBuffer(ScannerController.ScanRequestBody(sources: []))
        }) { response in
            XCTAssertEqual(response.status, .badRequest, "A valid token must reach the controller")
        }

        try app.test(.GET, "/api/songs") { response in
            XCTAssertEqual(response.status, .ok, "Read endpoints must not require the admin token")
        }
    }

    func testCreateAndGetPlaylist() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        struct CreateBody: Codable {
            let name: String
            let description: String?
        }

        // Create playlist with explicit struct
        try app.test(.POST, "/api/playlists", beforeRequest: { req in
            req.body = jsonBuffer(CreateBody(name: "My Favorites", description: "Test playlist"))
            req.headers.contentType = .json
        }) { res in
            XCTAssertEqual(res.status, .ok)
        }

        // List playlists
        try app.test(.GET, "/api/playlists") { res in
            XCTAssertEqual(res.status, .ok)
            let playlists = try res.content.decode([PlaylistResponse].self)
            XCTAssertEqual(playlists.count, 1)
            XCTAssertEqual(playlists[0].name, "My Favorites")
            XCTAssertEqual(playlists[0].description, "Test playlist")
        }
    }

    func testPlaylistIndexReportsSongCountForAtomicSave() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        struct CreateBody: Codable {
            let name: String
            let songIds: [UUID]
        }
        let songs = (1...2).map { index in
            Song(
                title: "Atomic \(index)",
                sha256: "atomic-playlist-\(String(format: "%047d", index))",
                fileFormat: "mp3",
                fileSize: 100
            )
        }
        for song in songs { try song.create(on: app.db).wait() }

        try app.test(.POST, "/api/playlists", beforeRequest: { request in
            request.body = jsonBuffer(CreateBody(name: "Atomic", songIds: songs.compactMap(\.id)))
            request.headers.contentType = .json
        }) { response in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(try response.content.decode(PlaylistResponse.self).songCount, 2)
        }

        try Playlist(name: "Empty").create(on: app.db).wait()

        try app.test(.GET, "/api/playlists") { response in
            let playlists = try response.content.decode([PlaylistResponse].self)
            XCTAssertEqual(playlists.count, 2)
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: playlists.map { ($0.name, $0.songCount) }),
                ["Atomic": 2, "Empty": 0]
            )
        }
    }

    func testAtomicPlaylistSaveRollsBackWhenAnySongIsMissing() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        struct CreateBody: Codable {
            let name: String
            let songIds: [UUID]
        }
        let song = Song(
            title: "Existing", sha256: "atomic-rollback-existing-00000000000000000000000",
            fileFormat: "mp3", fileSize: 100
        )
        try song.create(on: app.db).wait()

        try app.test(.POST, "/api/playlists", beforeRequest: { request in
            request.body = jsonBuffer(CreateBody(
                name: "Must Roll Back", songIds: [song.id!, UUID()]
            ))
            request.headers.contentType = .json
        }) { response in
            XCTAssertEqual(response.status, .notFound)
        }

        try app.test(.GET, "/api/playlists") { response in
            XCTAssertTrue(try response.content.decode([PlaylistResponse].self).isEmpty)
        }
        XCTAssertEqual(try PlaylistSongPivot.query(on: app.db).count().wait(), 0)
    }

    func testUpdatePlaylist() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        struct CreateBody: Codable {
            let name: String
        }
        struct UpdateBody: Codable {
            let name: String
            let description: String
        }

        // Get the created playlist ID by inspecting the response
        var playlistId: UUID?

        try app.test(.POST, "/api/playlists", beforeRequest: { req in
            req.body = jsonBuffer(CreateBody(name: "Test"))
            req.headers.contentType = .json
        }) { res in
            let pl = try res.content.decode(PlaylistResponse.self)
            playlistId = pl.id
        }

        guard let plId = playlistId else { XCTFail("Failed to create playlist"); return }

        // Update
        try app.test(.PUT, "/api/playlists/\(plId)", beforeRequest: { req in
            req.body = jsonBuffer(UpdateBody(name: "Updated", description: "Changed"))
            req.headers.contentType = .json
        }) { res2 in
            XCTAssertEqual(res2.status, .ok)
            let updated = try res2.content.decode(PlaylistResponse.self)
            XCTAssertEqual(updated.name, "Updated")
            XCTAssertEqual(updated.description, "Changed")
        }
    }

    func testDeletePlaylist() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        struct CreateBody: Codable {
            let name: String
        }

        var playlistId: UUID?
        try app.test(.POST, "/api/playlists", beforeRequest: { req in
            req.body = jsonBuffer(CreateBody(name: "ToDelete"))
            req.headers.contentType = .json
        }) { res in
            let pl = try res.content.decode(PlaylistResponse.self)
            playlistId = pl.id
        }

        guard let plId = playlistId else { XCTFail("Failed to create playlist"); return }

        // Delete
        try app.test(.DELETE, "/api/playlists/\(plId)") { res2 in
            XCTAssertEqual(res2.status, .noContent)
        }

        // Verify deleted
        try app.test(.GET, "/api/playlists") { res3 in
            let playlists = try res3.content.decode([PlaylistResponse].self)
            XCTAssertEqual(playlists.count, 0)
        }
    }

    func testCreateAndGetArtist() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        // Create artist directly
        let artist = Artist(name: "Test Artist")
        try artist.create(on: app.db).wait()

        // Get via API
        try app.test(.GET, "/api/artists?per=50") { res in
            XCTAssertEqual(res.status, .ok)
            let page = try res.content.decode(Page<ArtistResponse>.self)
            XCTAssertEqual(page.items.count, 1)
            XCTAssertEqual(page.items[0].name, "Test Artist")
        }
    }

    func testCreateAndGetSong() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        // Create artist + song
        let artist = Artist(name: "Artist")
        try artist.create(on: app.db).wait()

        let song = Song(title: "Test Song", sha256: "abcdef1234567890abcdef1234567890abcdef12", fileFormat: "mp3", fileSize: 1234)
        song.$artist.id = artist.id!
        try song.create(on: app.db).wait()

        // Get song list
        try app.test(.GET, "/api/songs") { res in
            XCTAssertEqual(res.status, .ok)
            let page = try res.content.decode(Page<SongResponse>.self)
            XCTAssertEqual(page.items.count, 1)
            XCTAssertEqual(page.items[0].title, "Test Song")
            XCTAssertEqual(page.items[0].fileFormat, "mp3")
            XCTAssertEqual(page.items[0].playStrategy, "directFile")
            XCTAssertNotNil(page.items[0].artist)
            XCTAssertEqual(page.items[0].artist?.name, "Artist")
        }
    }

    func testSongSearch() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        // Create songs
        let artist = Artist(name: "Test Band")
        try artist.create(on: app.db).wait()

        let song1 = Song(title: "Rock Anthem", sha256: "aaaabbbbccccddddeeeeffff0000111122223333", fileFormat: "mp3", fileSize: 100)
        song1.$artist.id = artist.id!
        try song1.create(on: app.db).wait()

        let song2 = Song(title: "Jazz Vibes", sha256: "bbbbccccddddeeeeffff00001111222233334444", fileFormat: "mp3", fileSize: 200)
        song2.$artist.id = artist.id!
        try song2.create(on: app.db).wait()

        // Search by title
        try app.test(.GET, "/api/songs/search?q=rock") { res in
            XCTAssertEqual(res.status, .ok)
            let songs = try res.content.decode([SongResponse].self)
            XCTAssertEqual(songs.count, 1)
            XCTAssertEqual(songs[0].title, "Rock Anthem")
        }

        // Search by artist
        try app.test(.GET, "/api/songs/search?q=band") { res in
            XCTAssertEqual(res.status, .ok)
            let songs = try res.content.decode([SongResponse].self)
            XCTAssertEqual(songs.count, 2)
        }

        // Search with no results
        try app.test(.GET, "/api/songs/search?q=nonexistent") { res in
            XCTAssertEqual(res.status, .ok)
            let songs = try res.content.decode([SongResponse].self)
            XCTAssertEqual(songs.count, 0)
        }

        // Empty query
        try app.test(.GET, "/api/songs/search?q=") { res in
            XCTAssertEqual(res.status, .ok)
            let songs = try res.content.decode([SongResponse].self)
            XCTAssertEqual(songs.count, 0)
        }
    }

    func testAddAndRemovePlaylistSongs() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        struct CreateBody: Codable {
            let name: String
        }
        struct AddSongBody: Codable {
            let songId: UUID
        }

        // Create artist, songs
        let artist = Artist(name: "Artist")
        try artist.create(on: app.db).wait()

        let song1 = Song(title: "S1", sha256: "1111222233334444555566667777888899990000", fileFormat: "mp3", fileSize: 100)
        song1.$artist.id = artist.id!
        try song1.create(on: app.db).wait()

        let song2 = Song(title: "S2", sha256: "2222333344445555666677778888999900001111", fileFormat: "mp3", fileSize: 200)
        song2.$artist.id = artist.id!
        try song2.create(on: app.db).wait()

        // Create playlist
        var playlistId: UUID!
        try app.test(.POST, "/api/playlists", beforeRequest: { req in
            req.body = jsonBuffer(CreateBody(name: "Test PL"))
            req.headers.contentType = .json
        }) { res in
            let pl = try res.content.decode(PlaylistResponse.self)
            playlistId = pl.id
        }

        // Add song1
        try app.test(.POST, "/api/playlists/\(playlistId!)/songs", beforeRequest: { req in
            req.body = jsonBuffer(AddSongBody(songId: song1.id!))
            req.headers.contentType = .json
        }) { res in
            XCTAssertEqual(res.status, .created)
        }

        // Add song2
        try app.test(.POST, "/api/playlists/\(playlistId!)/songs", beforeRequest: { req in
            req.body = jsonBuffer(AddSongBody(songId: song2.id!))
            req.headers.contentType = .json
        }) { res in
            XCTAssertEqual(res.status, .created)
        }

        // Get playlist should have 2 songs
        try app.test(.GET, "/api/playlists/\(playlistId!)") { res in
            XCTAssertEqual(res.status, .ok)
            let pl = try res.content.decode(PlaylistResponse.self)
            XCTAssertEqual(pl.songs?.count, 2)
        }

        // Remove song1
        try app.test(.DELETE, "/api/playlists/\(playlistId!)/songs/\(song1.id!)") { res in
            XCTAssertEqual(res.status, .noContent)
        }

        // Verify only 1 song left
        try app.test(.GET, "/api/playlists/\(playlistId!)") { res in
            let pl = try res.content.decode(PlaylistResponse.self)
            XCTAssertEqual(pl.songs?.count, 1)
            XCTAssertEqual(pl.songs?.first?.title, "S2")
        }
    }

    func testNotFoundError() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        let fakeId = "00000000-0000-0000-0000-000000000000"

        try app.test(.GET, "/api/songs/\(fakeId)") { res in
            XCTAssertEqual(res.status, .notFound)
        }

        try app.test(.GET, "/api/artists/\(fakeId)") { res in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    // MARK: - Health Endpoint

    func testHealthEndpointReturnsReady() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        // 创建 CAS 目录以保证健康检查通过
        try FileManager.default.createDirectory(atPath: app.casStorage.root, withIntermediateDirectories: true)

        try app.test(.GET, "/api/health") { res in
            XCTAssertEqual(res.status, .ok)
            let health = try res.content.decode(HealthResponse.self)
            XCTAssertEqual(health.status, "ready")
            XCTAssertEqual(health.version, AppVersion.current)
            XCTAssertEqual(health.commit, "unknown")
            XCTAssertEqual(health.database, "healthy")
            XCTAssertEqual(health.cas, "healthy")
        }
    }

    func testHealthEndpointReturnsDegradedWhenCasUnavailable() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateArtist())
        app.migrations.add(CreateAlbum())
        app.migrations.add(CreateSong())
        app.migrations.add(CreatePlaylist())
        app.migrations.add(CreatePlaylistSongPivot())
        try routes(app)
        // CAS 指向不存在的目录
        app.casStorage = CasStorageService(root: NSTemporaryDirectory() + "cas-nonexistent-\(UUID().uuidString)")
        try app.autoMigrate().wait()

        try app.test(.GET, "/api/health") { res in
            XCTAssertEqual(res.status, .serviceUnavailable)
            let health = try res.content.decode(HealthResponse.self)
            XCTAssertEqual(health.status, "degraded")
            XCTAssertEqual(health.database, "healthy")
            XCTAssertEqual(health.cas, "unhealthy")
        }
    }

    func testOpenAPIEndpoint() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        try app.test(.GET, "/api/openapi.json") { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType, .json)
            let body = try JSONSerialization.jsonObject(with: res.body) as? [String: Any]
            XCTAssertEqual(body?["openapi"] as? String, "3.0.3")
            XCTAssertNotNil(body?["paths"])

            // R01: info.version 来自 AppVersion，不应是旧硬编码值
            let info = body?["info"] as? [String: Any]
            let version = info?["version"] as? String
            XCTAssertNotNil(version, "info.version should be present")
            XCTAssertNotEqual(version, "1.1.0", "version should no longer be the old hardcoded value")
            XCTAssertEqual(version, AppVersion.current, "OpenAPI version should match AppVersion.current")
        }
    }

    // MARK: - Artist Endpoints

    func testArtistDetailWithSongCount() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        let artist = Artist(name: "Detail Artist")
        try artist.create(on: app.db).wait()

        let song1 = Song(title: "S1", sha256: "33334444555566667777888899990000aaaa1111", fileFormat: "mp3", fileSize: 100)
        song1.$artist.id = artist.id!
        try song1.create(on: app.db).wait()

        let song2 = Song(title: "S2", sha256: "4444555566667777888899990000aaaa1111bbbb", fileFormat: "mp3", fileSize: 200)
        song2.$artist.id = artist.id!
        try song2.create(on: app.db).wait()

        try app.test(.GET, "/api/artists/\(artist.id!)") { res in
            XCTAssertEqual(res.status, .ok)
            let detail = try res.content.decode(ArtistResponse.self)
            XCTAssertEqual(detail.name, "Detail Artist")
            XCTAssertEqual(detail.songCount, 2)
        }

        try app.test(.GET, "/api/artists/\(artist.id!)/songs") { res in
            XCTAssertEqual(res.status, .ok)
            let page = try res.content.decode(Page<SongResponse>.self)
            XCTAssertEqual(page.items.count, 2)
        }
    }

    // MARK: - Delete Song

    func testDeleteSong() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        let artist = Artist(name: "A")
        try artist.create(on: app.db).wait()

        let song = Song(title: "Delete Me", sha256: "555566667777888899990000aaaa1111bbbb2222", fileFormat: "mp3", fileSize: 100)
        song.$artist.id = artist.id!
        try song.create(on: app.db).wait()

        try app.test(.DELETE, "/api/songs/\(song.id!)", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
        }) { res in
            XCTAssertEqual(res.status, .noContent)
        }

        try app.test(.GET, "/api/songs") { res in
            let page = try res.content.decode(Page<SongResponse>.self)
            XCTAssertEqual(page.items.count, 0)
        }
    }

    func testSongFormatSummaryAndEmptyLibrary() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        try app.test(.GET, "/api/songs/formats") { response in
            XCTAssertEqual(response.status, .ok)
            let summary = try response.content.decode(SongController.FormatSummary.self)
            XCTAssertEqual(summary.total, 0)
            XCTAssertTrue(summary.formats.isEmpty)
        }

        for (index, format) in ["ym", "YM", "mp3", "custom"].enumerated() {
            let song = Song(
                title: "Format \(index)",
                sha256: "format-summary-\(String(format: "%049d", index))",
                fileFormat: format,
                fileSize: 100
            )
            try song.create(on: app.db).wait()
        }

        try app.test(.GET, "/api/songs/formats") { response in
            let summary = try response.content.decode(SongController.FormatSummary.self)
            XCTAssertEqual(summary.total, 4)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: summary.formats.map { ($0.format, $0.count) }), ["custom": 1, "mp3": 1, "ym": 2])
        }
    }

    func testSongSearchCanFilterByFormat() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        let artist = Artist(name: "Demo Artist")
        try artist.create(on: app.db).wait()
        for (index, format) in ["ym", "mp3"].enumerated() {
            let song = Song(title: "Shared title", sha256: "search-format-\(String(format: "%050d", index))", fileFormat: format, fileSize: 100)
            song.$artist.id = artist.id!
            try song.create(on: app.db).wait()
        }

        try app.test(.GET, "/api/songs/search?q=shared&format=ym") { response in
            XCTAssertEqual(response.status, .ok)
            let songs = try response.content.decode([SongResponse].self)
            XCTAssertEqual(songs.map(\.fileFormat), ["ym"])
        }
    }

    func testSongSearchEagerLoadsOptionalArtistAndAlbum() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        let artist = Artist(name: "Bounded Artist")
        try artist.create(on: app.db).wait()
        let album = Album(artistId: artist.id!, title: "Bounded Album")
        try album.create(on: app.db).wait()

        let related = Song(
            title: "Bounded related",
            sha256: "search-eager-related-00000000000000000000000000000",
            fileFormat: "mp3",
            fileSize: 100
        )
        related.$artist.id = artist.id!
        related.$album.id = album.id!
        try related.create(on: app.db).wait()

        let standalone = Song(
            title: "Bounded standalone",
            sha256: "search-eager-standalone-0000000000000000000000000",
            fileFormat: "mp3",
            fileSize: 100
        )
        try standalone.create(on: app.db).wait()

        try app.test(.GET, "/api/songs/search?q=bounded") { response in
            XCTAssertEqual(response.status, .ok)
            let songs = try response.content.decode([SongResponse].self)
            XCTAssertEqual(songs.count, 2)
            let byTitle = Dictionary(uniqueKeysWithValues: songs.map { ($0.title, $0) })
            XCTAssertEqual(byTitle["Bounded related"]?.artist?.name, "Bounded Artist")
            XCTAssertEqual(byTitle["Bounded related"]?.album?.title, "Bounded Album")
            XCTAssertNil(byTitle["Bounded standalone"]?.artist)
            XCTAssertNil(byTitle["Bounded standalone"]?.album)
        }

        try app.test(.GET, "/api/songs/search?q=artist") { response in
            let songs = try response.content.decode([SongResponse].self)
            XCTAssertEqual(songs.map(\.title), ["Bounded related"])
            XCTAssertEqual(songs[0].artist?.name, "Bounded Artist")
        }

        let quoted = Song(
            title: "Coder's Theme",
            sha256: "search-bound-quote-0000000000000000000000000000000",
            fileFormat: "mp3",
            fileSize: 100
        )
        try quoted.create(on: app.db).wait()
        try app.test(.GET, "/api/songs/search?q=coder%27s") { response in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(try response.content.decode([SongResponse].self).map(\.title), ["Coder's Theme"])
        }
        try app.test(.GET, "/api/songs/search?q=%27%20OR%201%3D1%20--") { response in
            XCTAssertEqual(response.status, .ok)
            XCTAssertTrue(try response.content.decode([SongResponse].self).isEmpty)
        }
    }

    func testSongListAndSearchDoNotBackfillMissingDuration() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        let song = Song(
            title: "Duration remains missing",
            sha256: "duration-not-backfilled-0000000000000000000000000000",
            fileFormat: "wav",
            fileSize: 48,
            duration: nil
        )
        try song.create(on: app.db).wait()

        let path = app.casStorage.resolve(sha256: song.sha256, format: song.fileFormat)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try PCMData(samples: Data([0x00, 0x00, 0x00, 0x00])).encodeWAV()
            .write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: app.casStorage.root) }

        try app.test(.GET, "/api/songs") { response in
            XCTAssertEqual(response.status, .ok)
            let page = try response.content.decode(Page<SongResponse>.self)
            XCTAssertEqual(page.items.count, 1)
            XCTAssertNil(page.items[0].duration)
        }

        try app.test(.GET, "/api/songs/search?q=duration") { response in
            XCTAssertEqual(response.status, .ok)
            let songs = try response.content.decode([SongResponse].self)
            XCTAssertEqual(songs.count, 1)
            XCTAssertNil(songs[0].duration)
        }

        let persisted = try Song.find(song.id!, on: app.db).wait()
        XCTAssertNil(persisted?.duration)
    }

    func testDurationBackfillIsDryRunSafeAndToleratesMissingCASFiles() async throws {
        let app = try await createAsyncTestApp()
        let casRoot = app.casStorage.root
        defer { try? FileManager.default.removeItem(atPath: casRoot) }

        do {
            let validSong = Song(
                title: "Backfill duration",
                sha256: "duration-backfill-valid-00000000000000000000000000",
                fileFormat: "wav",
                fileSize: 176_444
            )
            let missingSong = Song(
                title: "Missing CAS file",
                sha256: "duration-backfill-missing-000000000000000000000000",
                fileFormat: "wav",
                fileSize: 176_444
            )
            try await validSong.create(on: app.db)
            try await missingSong.create(on: app.db)

            let path = app.casStorage.resolve(sha256: validSong.sha256, format: validSong.fileFormat)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try PCMData(samples: Data(repeating: 0, count: 176_400))
                .encodeWAV()
                .write(to: URL(fileURLWithPath: path))

            let service = DurationBackfillService(database: app.db, cas: app.casStorage)
            let dryRun = try await service.run(options: .init(batchSize: 1, concurrency: 1, dryRun: true))
            XCTAssertEqual(dryRun.selected, 2)
            XCTAssertEqual(dryRun.updated, 0)
            let durationAfterDryRun = try await Song.find(validSong.id!, on: app.db)?.duration
            XCTAssertNil(durationAfterDryRun)

            let firstRun = try await service.run(options: .init(batchSize: 2, concurrency: 2))
            XCTAssertEqual(firstRun.selected, 2)
            XCTAssertEqual(firstRun.updated, 1)
            XCTAssertEqual(firstRun.missingFiles, 1)
            XCTAssertEqual(firstRun.probeFailures, 0)
            let validDuration = try await Song.find(validSong.id!, on: app.db)?.duration
            XCTAssertNotNil(validDuration)
            XCTAssertEqual(validDuration!, 1, accuracy: 0.01)
            let missingDuration = try await Song.find(missingSong.id!, on: app.db)?.duration
            XCTAssertNil(missingDuration)

            let rerun = try await service.run(options: .init(batchSize: 2, concurrency: 1))
            XCTAssertEqual(rerun.selected, 1)
            XCTAssertEqual(rerun.updated, 0)
            XCTAssertEqual(rerun.missingFiles, 1)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    func testSongListIndexMigrationCreatesAndRevertsStableIndexes() async throws {
        let app = try await createAsyncTestApp()
        struct IndexRow: Decodable {
            let name: String
        }

        do {
            let sql = try XCTUnwrap(app.db as? any SQLDatabase)
            func indexNames() async throws -> Set<String> {
                let rows = try await sql.raw(
                    "SELECT name FROM sqlite_master " +
                    "WHERE type = 'index' AND name LIKE 'idx_songs_%'"
                ).all(decoding: IndexRow.self)
                return Set(rows.map(\.name))
            }

            let createdNames = try await indexNames()
            XCTAssertEqual(createdNames, [
                CreateSongListIndexes.createdIndex,
                CreateSongListIndexes.formatIndex,
            ])
            try await CreateSongListIndexes().revert(on: app.db)
            let revertedNames = try await indexNames()
            XCTAssertTrue(revertedNames.isEmpty)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    func testCasStorageHashesAndCopiesSourceFile() async throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cas-store-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let source = temporaryRoot.appendingPathComponent("source.ym")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try Data("OrzMusic\n".utf8).write(to: source)

        let cas = CasStorageService(root: temporaryRoot.appendingPathComponent("cas").path)
        let stored = try await cas.store(sourcePath: source.path)

        XCTAssertEqual(stored.sha256, "9acb24a3dd4c066176e619bb6441eee64f727c62372631e6474f40c7f72947e7")
        XCTAssertEqual(stored.ext, "ym")
        XCTAssertEqual(stored.fileSize, 9)
        XCTAssertTrue(cas.contains(sha256: stored.sha256, format: stored.ext))
        let destination = URL(fileURLWithPath: cas.resolve(sha256: stored.sha256, format: stored.ext))
        XCTAssertEqual(try Data(contentsOf: destination), Data("OrzMusic\n".utf8))
    }

    func testScannerUsesFilenameArtistWhenScanningSourceDirectoryRoot() throws {
        let app = try createTestApp()
        defer { app.shutdown() }
        let scanner = MusicScannerService(sourcePaths: [], cas: app.casStorage, db: app.db)

        let metadata = scanner.parseMetadata(
            relativePath: "iOTA - ACDSee Pro 5.3 build 168 crk.v2m",
            fileName: "iOTA - ACDSee Pro 5.3 build 168 crk.v2m"
        )

        XCTAssertEqual(metadata.artistName, "iOTA")
        XCTAssertEqual(metadata.songTitle, "ACDSee Pro 5.3 build 168")
    }

    func testScannerOnlyFingerprintsContainerAudioFormats() throws {
        let app = try createTestApp()
        defer { app.shutdown() }
        let scanner = MusicScannerService(sourcePaths: [], cas: app.casStorage, db: app.db)

        XCTAssertTrue(scanner.shouldGenerateAudioFingerprint(format: "mp3"))
        XCTAssertTrue(scanner.shouldGenerateAudioFingerprint(format: "ogg"))
        XCTAssertTrue(scanner.shouldGenerateAudioFingerprint(format: "wav"))

        XCTAssertFalse(scanner.shouldGenerateAudioFingerprint(format: "xm"))
        XCTAssertFalse(scanner.shouldGenerateAudioFingerprint(format: "mod"))
        XCTAssertFalse(scanner.shouldGenerateAudioFingerprint(format: "v2m"))
        XCTAssertFalse(scanner.shouldGenerateAudioFingerprint(format: "sc68"))
        XCTAssertFalse(scanner.shouldGenerateAudioFingerprint(format: "ym"))
        XCTAssertFalse(scanner.shouldGenerateAudioFingerprint(format: "unknown"))
    }

    // MARK: - Playlist Reorder

    func testPlaylistReorder() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        struct CreateBody: Codable {
            let name: String
        }
        struct AddSongBody: Codable {
            let songId: UUID
        }
        struct ReorderBody: Codable {
            let songIds: [UUID]
        }

        let artist = Artist(name: "A")
        try artist.create(on: app.db).wait()

        let songs = (1...3).map { i in
            let s = Song(title: "S\(i)", sha256: "song-hash-\(String(format: "%040x", i))", fileFormat: "mp3", fileSize: i * 100)
            s.$artist.id = artist.id!
            try! s.create(on: app.db).wait()
            return s
        }

        // Create playlist
        var playlistId: UUID!
        try app.test(.POST, "/api/playlists", beforeRequest: { req in
            req.body = jsonBuffer(CreateBody(name: "Reorder PL"))
            req.headers.contentType = .json
        }) { res in
            let pl = try res.content.decode(PlaylistResponse.self)
            playlistId = pl.id
        }

        // Add songs in order S1, S2, S3
        for song in songs {
            try app.test(.POST, "/api/playlists/\(playlistId!)/songs", beforeRequest: { req in
                req.body = jsonBuffer(AddSongBody(songId: song.id!))
                req.headers.contentType = .json
            }) { res in
                XCTAssertEqual(res.status, .created)
            }
        }

        // Reorder: S3, S1, S2
        let reorderIds = [songs[2].id!, songs[0].id!, songs[1].id!]
        try app.test(.PUT, "/api/playlists/\(playlistId!)/songs/reorder", beforeRequest: { req in
            req.body = jsonBuffer(ReorderBody(songIds: reorderIds))
            req.headers.contentType = .json
        }) { res in
            XCTAssertEqual(res.status, .ok)
        }

        // Verify order
        try app.test(.GET, "/api/playlists/\(playlistId!)") { res in
            let pl = try res.content.decode(PlaylistResponse.self)
            XCTAssertEqual(pl.songs?.count, 3)
            XCTAssertEqual(pl.songs?[0].title, "S3")
            XCTAssertEqual(pl.songs?[1].title, "S1")
            XCTAssertEqual(pl.songs?[2].title, "S2")
        }
    }

    // MARK: - Song Location

    func testSongLocationFirstSong() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        let songs = (1...5).map { i in
            let s = Song(id: orderedUUID(i), title: "L\(i)", sha256: "loc-hash-\(String(format: "%049d", i))", fileFormat: "mp3", fileSize: i * 100)
            try! s.create(on: app.db).wait()
            return s
        }

        // The last-created song should be first (index 0) in createdAt DESC order
        let lastId = songs.last!.id!
        try app.test(.GET, "/api/songs/\(lastId)/location") { res in
            XCTAssertEqual(res.status, .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            XCTAssertEqual(loc.songId, lastId)
            XCTAssertEqual(loc.index, 0)
            XCTAssertEqual(loc.page, 1)
            XCTAssertEqual(loc.per, 50)
        }
    }

    func testSongLocationPerPageBoundary() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        // Create 15 songs
        let songs = (1...15).map { i in
            let s = Song(id: orderedUUID(i), title: "B\(i)", sha256: "loc-b-\(String(format: "%048d", i))", fileFormat: "mp3", fileSize: i * 100)
            try! s.create(on: app.db).wait()
            return s
        }

        // per=5, 5th from newest = index 4 → page 1, 6th from newest = index 5 → page 2
        let songIdx4 = songs[songs.count - 5].id!
        let songIdx5 = songs[songs.count - 6].id!

        try app.test(.GET, "/api/songs/\(songIdx4)/location?per=5") { res in
            XCTAssertEqual(res.status, .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            XCTAssertEqual(loc.index, 4)
            XCTAssertEqual(loc.page, 1)
            XCTAssertEqual(loc.per, 5)
        }

        try app.test(.GET, "/api/songs/\(songIdx5)/location?per=5") { res in
            XCTAssertEqual(res.status, .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            XCTAssertEqual(loc.index, 5)
            XCTAssertEqual(loc.page, 2)
            XCTAssertEqual(loc.per, 5)
        }
    }

    func testSongLocationLastPage() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        // Create 12 songs
        let songs = (1...12).map { i in
            let s = Song(id: orderedUUID(i), title: "LP\(i)", sha256: "loc-lp-\(String(format: "%048d", i))", fileFormat: "mp3", fileSize: i * 100)
            try! s.create(on: app.db).wait()
            return s
        }

        // per=5: indexes 0-4 → page 1, 5-9 → page 2, 10-11 → page 3
        // First-created song → last in sort (index 11) → page 3
        let firstSong = songs.first!.id!
        try app.test(.GET, "/api/songs/\(firstSong)/location?per=5") { res in
            XCTAssertEqual(res.status, .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            XCTAssertEqual(loc.index, 11)
            XCTAssertEqual(loc.page, 3)
            XCTAssertEqual(loc.per, 5)
        }
    }

    func testSongLocationStableOrder() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        // Create 3 songs with no time gap (same createdAt timestamp)
        // Fluent's @Timestamp uses second precision for .create,
        // so songs created within the same second get the same createdAt.
        // The id DESC tiebreaker ensures stable ordering.
        let songs = (1...3).map { i in
            let s = Song(id: orderedUUID(i), title: "Stable\(i)", sha256: "loc-stable-\(String(format: "%048d", i))", fileFormat: "mp3", fileSize: i * 100)
            try! s.create(on: app.db).wait()
            return s
        }

        // In createdAt DESC, id DESC order, the last-created song is first
        let lastCreated = songs.last!.id!
        try app.test(.GET, "/api/songs/\(lastCreated)/location") { res in
            XCTAssertEqual(res.status, .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            XCTAssertEqual(loc.index, 0)
        }
    }

    func testSongLocationUnknownId() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        let fakeId = "00000000-0000-0000-0000-000000000000"
        try app.test(.GET, "/api/songs/\(fakeId)/location") { res in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    func testSongLocationInvalidPerParams() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        let song = Song(title: "PerTest", sha256: "loc-per-test-\(String(format: "%048d", 1))", fileFormat: "mp3", fileSize: 100)
        try song.create(on: app.db).wait()
        guard let songId = song.id else { XCTFail("no id"); return }

        // per=0
        try app.test(.GET, "/api/songs/\(songId)/location?per=0") { res in
            XCTAssertEqual(res.status, .badRequest)
        }

        // per=101
        try app.test(.GET, "/api/songs/\(songId)/location?per=101") { res in
            XCTAssertEqual(res.status, .badRequest)
        }

        // non-numeric per
        try app.test(.GET, "/api/songs/\(songId)/location?per=abc") { res in
            XCTAssertEqual(res.status, .badRequest)
        }

        // negative per
        try app.test(.GET, "/api/songs/\(songId)/location?per=-1") { res in
            XCTAssertEqual(res.status, .badRequest)
        }
    }

    func testSongLocationResponseMatchesIndexApi() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        // Create 7 songs
        let songs = (1...7).map { i in
            let s = Song(id: orderedUUID(i), title: "Match\(i)", sha256: "loc-match-\(String(format: "%048d", i))", fileFormat: "mp3", fileSize: i * 100)
            try! s.create(on: app.db).wait()
            return s
        }

        // per=3: 4th-from-newest → index 3, page 2
        let midIdx = songs[songs.count - 4].id!
        try app.test(.GET, "/api/songs/\(midIdx)/location?per=3") { res in
            XCTAssertEqual(res.status, .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            XCTAssertEqual(loc.index, 3)
            XCTAssertEqual(loc.page, 2)
            XCTAssertEqual(loc.per, 3)

            // Verify that page 2 of /api/songs contains this song
            try app.test(.GET, "/api/songs?page=2&per=3") { pageRes in
                XCTAssertEqual(pageRes.status, .ok)
                let page = try pageRes.content.decode(Page<SongResponse>.self)
                let found = page.items.contains(where: { $0.id == midIdx })
                XCTAssertTrue(found, "Song should appear on page 2 of /api/songs")
            }
        }

        // First song in sort (newest) = index 0, page 1
        let firstId = songs.last!.id!
        try app.test(.GET, "/api/songs/\(firstId)/location?per=3") { res in
            XCTAssertEqual(res.status, .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            XCTAssertEqual(loc.index, 0)
            XCTAssertEqual(loc.page, 1)

            try app.test(.GET, "/api/songs?page=1&per=3") { pageRes in
                XCTAssertEqual(pageRes.status, .ok)
                let page = try pageRes.content.decode(Page<SongResponse>.self)
                let found = page.items.contains(where: { $0.id == firstId })
                XCTAssertTrue(found, "First song should appear on page 1 of /api/songs")
            }
        }
    }
}
