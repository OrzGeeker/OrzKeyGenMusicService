import Foundation
@testable import App
@testable import OrzAudioKit
import VaporTesting
import Testing
import Fluent
import FluentSQL
import FluentSQLiteDriver

@Suite(.serialized) struct AppTests {

    private struct AdminAPIErrorResponse: Content {
        let error: String
        let reason: String
        let code: Int
    }

    private struct UploadAPIResponse: Content {
        let status: String
        let song: SongResponse
    }

    private func multipartUploadBody(
        fileBytes: [UInt8],
        filename: String,
        fields: [String: String] = [:],
        boundary: String = "orz-upload-test-boundary"
    ) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: fileBytes.count + 1024)
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.writeString("Content-Type: application/octet-stream\r\n\r\n")
        body.writeBytes(fileBytes)
        body.writeString("\r\n")
        for key in fields.keys.sorted() {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            body.writeString(fields[key]!)
            body.writeString("\r\n")
        }
        body.writeString("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Test Lifecycle

    private func createTestApp(scanRoot: String? = nil) async throws -> Application {
        try await createAsyncTestApp(scanRoot: scanRoot)
    }

    private func createAsyncTestApp(scanRoot: String? = nil) async throws -> Application {
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.adminAPIToken = "test-admin-token"
        app.scanRoot = scanRoot
        app.middleware.use(ErrorResponseMiddleware())
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

    @Test func testAudioFormatDetection() async throws {
        // All supported formats
        #expect(AudioFormat.from(fileExtension: "xm") != nil)
        #expect(AudioFormat.from(fileExtension: "mod") != nil)
        #expect(AudioFormat.from(fileExtension: "it") != nil)
        #expect(AudioFormat.from(fileExtension: "s3m") != nil)
        #expect(AudioFormat.from(fileExtension: "mp3") != nil)
        #expect(AudioFormat.from(fileExtension: "ogg") != nil)
        #expect(AudioFormat.from(fileExtension: "wav") != nil)
        #expect(AudioFormat.from(fileExtension: "flac") != nil)
        #expect(AudioFormat.from(fileExtension: "sid") != nil)
        #expect(AudioFormat.from(fileExtension: "nsf") != nil)
        #expect(AudioFormat.from(fileExtension: "spc") != nil)
        #expect(AudioFormat.from(fileExtension: "v2m") != nil)

        // Unknown format
        #expect(AudioFormat.from(fileExtension: "unknown") == nil)
        #expect(AudioFormat.from(fileExtension: "txt") == nil)
        #expect(AudioFormat.from(fileExtension: "pdf") == nil)
    }

    @Test func testPlayStrategy() async throws {
        // directFile formats
        #expect(AudioFormat.from(fileExtension: "mp3")?.playStrategy.rawValue == "directFile")
        #expect(AudioFormat.from(fileExtension: "ogg")?.playStrategy.rawValue == "directFile")
        #expect(AudioFormat.from(fileExtension: "flac")?.playStrategy.rawValue == "directFile")
        #expect(AudioFormat.from(fileExtension: "mid")?.playStrategy.rawValue == "wasmDecode")

        // wasmDecode formats
        #expect(AudioFormat.from(fileExtension: "xm")?.playStrategy.rawValue == "wasmDecode")
        #expect(AudioFormat.from(fileExtension: "mod")?.playStrategy.rawValue == "wasmDecode")
        #expect(AudioFormat.from(fileExtension: "it")?.playStrategy.rawValue == "wasmDecode")
        #expect(AudioFormat.from(fileExtension: "s3m")?.playStrategy.rawValue == "wasmDecode")
        #expect(AudioFormat.from(fileExtension: "sid")?.playStrategy.rawValue == "wasmDecode")
        #expect(AudioFormat.from(fileExtension: "nsf")?.playStrategy.rawValue == "wasmDecode")
        #expect(AudioFormat.from(fileExtension: "bp")?.playStrategy.rawValue == "wasmDecode")

        // serverDecode formats (WAV may have ADPCM/GSM encoding, needs ffmpeg)
        #expect(AudioFormat.from(fileExtension: "wav")?.playStrategy.rawValue == "serverDecode")
    }

    @Test func testPCMEncodeWAV() async throws {
        let pcm = PCMData(samples: Data([0x00, 0x00, 0xFF, 0x7F]))
        let wav = pcm.encodeWAV()

        // WAV header: "RIFF" at start
        #expect(String(data: wav[0..<4], encoding: .utf8) == "RIFF")
        // WAV format: "WAVE"
        #expect(String(data: wav[8..<12], encoding: .utf8) == "WAVE")
        // fmt chunk
        #expect(String(data: wav[12..<16], encoding: .utf8) == "fmt ")
        // data chunk
        #expect(String(data: wav[36..<40], encoding: .utf8) == "data")

        // Total header is 44 bytes, data follows
        #expect(wav.count == 44 + 4) // header + 4 bytes of sample data
    }

    @Test func testPCMEncodeWAVEmptySamples() async throws {
        let pcm = PCMData()
        let wav = pcm.encodeWAV()
        // Valid header even with no samples
        #expect(String(data: wav[0..<4], encoding: .utf8) == "RIFF")
        #expect(wav.count == 44) // header only
    }

    @Test func testAudioEngineResolveStreamStrategy() async throws {
        let engine = AudioEngine()

        // directFile
        let mp3Strategy = engine.resolveStreamStrategy(filePath: "/test.mp3", format: .mp3)
        if case .directFile(let path, let mime) = mp3Strategy {
            #expect(path == "/test.mp3")
            #expect(mime == "audio/mpeg")
        } else {
            Issue.record("Expected directFile strategy for mp3")
        }

        // wasmDecode
        let xmStrategy = engine.resolveStreamStrategy(filePath: "/test.xm", format: .xm)
        if case .wasmDecode(let path, let fmt) = xmStrategy {
            #expect(path == "/test.xm")
            #expect(fmt == .xm)
        } else {
            Issue.record("Expected wasmDecode strategy for xm")
        }

        // SoundMon BP is decoded by the shared native/WASM C decoder.
        let bpStrategy = engine.resolveStreamStrategy(filePath: "/test.bp", format: .bp)
        if case .wasmDecode(let path, let fmt) = bpStrategy {
            #expect(path == "/test.bp")
            #expect(fmt == .bp)
        } else {
            Issue.record("Expected wasmDecode strategy for bp")
        }
    }

    @Test func testAudioFormatMimeTypes() async throws {
        #expect(AudioFormat.mp3.mimeType == "audio/mpeg")
        #expect(AudioFormat.ogg.mimeType == "audio/ogg")
        #expect(AudioFormat.wav.mimeType == "audio/wav")
        #expect(AudioFormat.flac.mimeType == "audio/flac")
        #expect(AudioFormat.mid.mimeType == "audio/midi")
        #expect(AudioFormat.xm.mimeType == "audio/x-mod")
        #expect(AudioFormat.sid.mimeType == "application/octet-stream")
    }

    // MARK: - API Integration Tests

    @Test func testStatsEndpoint() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        try await app.test(.GET, "/api/stats") { res in
            #expect(res.status == .ok)
            let stats = try res.content.decode(StatsResponse.self)
            #expect(stats.totalSongs == 0)
            #expect(stats.totalArtists == 0)
            #expect(stats.totalAlbums == 0)
            #expect(stats.totalPlaylists == 0)
        }
    }

    @Test func testEmptySongsList() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        try await app.test(.GET, "/api/songs") { res in
            #expect(res.status == .ok)
            let page = try res.content.decode(Page<SongResponse>.self)
            #expect(page.items.count == 0)
            #expect(page.metadata.total == 0)
        }
    }

    @Test func testAdministrativeEndpointsRequireConfiguredBearerToken() async throws {
        let disabledApp = try await Application.make(.testing)
        defer { scheduleShutdown(disabledApp) }
        disabledApp.databases.use(.sqlite(.memory), as: .sqlite)
        disabledApp.adminAPIToken = nil
        disabledApp.casStorage = CasStorageService(root: NSTemporaryDirectory() + "cas-test-\(UUID().uuidString)")
        try routes(disabledApp)

        try await disabledApp.test(.POST, "/api/scan") { response in
            #expect(response.status == .serviceUnavailable)
            let body = try response.content.decode(AdminAPIErrorResponse.self)
            #expect(body.error == "admin_api_disabled")
        }

        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        try await app.test(.POST, "/api/upload") { response in
            #expect(response.status == .unauthorized)
        }

        try await app.test(.POST, "/api/upload", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
        }) { response in
            #expect(response.status != .unauthorized)
        }

        try await app.test(.DELETE, "/api/songs/\(UUID())", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .authorization, value: "Bearer wrong-token")
        }) { response in
            #expect(response.status == .unauthorized)
        }

        try await app.test(.POST, "/api/scan", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
            request.headers.contentType = .json
            request.body = jsonBuffer(["sources": ["/"]])
        }) { response in
            #expect(response.status == .serviceUnavailable, "A valid token must reach the controller")
            let body = try response.content.decode(AdminAPIErrorResponse.self)
            #expect(body.error == "scan_root_not_configured")
        }

        try await app.test(.GET, "/api/songs") { response in
            #expect(response.status == .ok, "Read endpoints must not require the admin token")
        }
    }

    @Test func testUploadReturnsCreatedThenDuplicateAndUsesExplicitMetadata() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }
        let boundary = "orz-upload-created-duplicate"
        let body = multipartUploadBody(
            fileBytes: Array("uploaded-module-content".utf8),
            filename: "Path Title.v2m",
            fields: [
                "relativePath": "Path Artist/Path Title.v2m",
                "artist": "Explicit Artist",
                "title": "Explicit Title",
            ],
            boundary: boundary
        )
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
        headers.contentType = .formData(boundary: boundary)

        var createdID: UUID?
        try await app.test(.POST, "/api/upload", headers: headers, body: body) { response in
            #expect(response.status == .created)
            let result = try response.content.decode(UploadAPIResponse.self)
            #expect(result.status == "created")
            #expect(result.song.title == "Explicit Title")
            #expect(result.song.artist?.name == "Explicit Artist")
            createdID = result.song.id
        }

        try await app.test(.POST, "/api/upload", headers: headers, body: body) { response in
            #expect(response.status == .ok)
            let result = try response.content.decode(UploadAPIResponse.self)
            #expect(result.status == "duplicate")
            #expect(result.song.id == createdID)
        }
        let count = try await Song.query(on: app.db).count()
        #expect(count == 1)
    }

    @Test func testUploadUsesRelativePathWhenExplicitMetadataIsAbsent() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }
        let boundary = "orz-upload-relative-path"
        let body = multipartUploadBody(
            fileBytes: Array("relative-path-module-content".utf8),
            filename: "Path Title.v2m",
            fields: ["relativePath": "Path Artist/Path Title.v2m"],
            boundary: boundary
        )
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
        headers.contentType = .formData(boundary: boundary)

        try await app.test(.POST, "/api/upload", headers: headers, body: body) { response in
            #expect(response.status == .created)
            let result = try response.content.decode(UploadAPIResponse.self)
            #expect(result.status == "created")
            #expect(result.song.title == "Path Title")
            #expect(result.song.artist?.name == "Path Artist")
        }
    }

    @Test func testUploadCleansUpTemporaryFileAfterImport() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }
        let boundary = "orz-upload-temp-cleanup"
        let temporaryDirectory = NSTemporaryDirectory()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory)
            .filter { $0.hasPrefix("orz_upload_") }
            .sorted()
        let body = multipartUploadBody(
            fileBytes: Array("temporary-upload-content".utf8),
            filename: "Temporary.v2m",
            boundary: boundary
        )
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
        headers.contentType = .formData(boundary: boundary)

        try await app.test(.POST, "/api/upload", headers: headers, body: body) { response in
            #expect(response.status == .created)
        }

        let filesAfter = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory)
            .filter { $0.hasPrefix("orz_upload_") }
            .sorted()
        #expect(filesAfter == filesBefore)
    }

    @Test func testUploadRejectsFileLargerThan32MiBBeforeCASOrDatabaseWrites() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }
        let boundary = "orz-upload-too-large"
        let fileBytes = Array(repeating: UInt8(0x42), count: UploadController.maximumUploadFileSize + 1)
        let body = multipartUploadBody(
            fileBytes: fileBytes,
            filename: "too-large.v2m",
            boundary: boundary
        )
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
        headers.contentType = .formData(boundary: boundary)

        try await app.test(.POST, "/api/upload", headers: headers, body: body) { response in
            #expect(response.status == .payloadTooLarge)
            let error = try response.content.decode(AdminAPIErrorResponse.self)
            #expect(error.error == "upload_too_large")
            #expect(error.code == 413)
        }
        let count = try await Song.query(on: app.db).count()
        #expect(count == 0)
        #expect(!FileManager.default.fileExists(atPath: app.casStorage.root))
    }

    @Test func testCreateAndGetPlaylist() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        struct CreateBody: Codable {
            let name: String
            let description: String?
        }

        // Create playlist with explicit struct
        try await app.test(.POST, "/api/playlists", beforeRequest: { req in
            req.body = jsonBuffer(CreateBody(name: "My Favorites", description: "Test playlist"))
            req.headers.contentType = .json
        }) { res in
            #expect(res.status == .ok)
        }

        // List playlists
        try await app.test(.GET, "/api/playlists") { res in
            #expect(res.status == .ok)
            let playlists = try res.content.decode([PlaylistResponse].self)
            #expect(playlists.count == 1)
            #expect(playlists[0].name == "My Favorites")
            #expect(playlists[0].description == "Test playlist")
        }
    }

    @Test func testPlaylistIndexReportsSongCountForAtomicSave() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

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
        for song in songs { try await song.create(on: app.db) }

        try await app.test(.POST, "/api/playlists", beforeRequest: { request in
            request.body = jsonBuffer(CreateBody(name: "Atomic", songIds: songs.compactMap(\.id)))
            request.headers.contentType = .json
        }) { response in
            #expect(response.status == .ok)
            let decoded = try response.content.decode(PlaylistResponse.self).songCount
            #expect(decoded == 2)
        }

        try await Playlist(name: "Empty").create(on: app.db)

        try await app.test(.GET, "/api/playlists") { response in
            let playlists = try response.content.decode([PlaylistResponse].self)
            #expect(playlists.count == 2)
            #expect(Dictionary(uniqueKeysWithValues: playlists.map { ($0.name, $0.songCount) }) == ["Atomic": 2, "Empty": 0])
        }
    }

    @Test func testAtomicPlaylistSaveRollsBackWhenAnySongIsMissing() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        struct CreateBody: Codable {
            let name: String
            let songIds: [UUID]
        }
        let song = Song(
            title: "Existing", sha256: "atomic-rollback-existing-00000000000000000000000",
            fileFormat: "mp3", fileSize: 100
        )
        try await song.create(on: app.db)

        try await app.test(.POST, "/api/playlists", beforeRequest: { request in
            request.body = jsonBuffer(CreateBody(
                name: "Must Roll Back", songIds: [song.id!, UUID()]
            ))
            request.headers.contentType = .json
        }) { response in
            #expect(response.status == .notFound)
        }

        try await app.test(.GET, "/api/playlists") { response in
            let decoded = try response.content.decode([PlaylistResponse].self)
            #expect(decoded.isEmpty)
        }
        let count = try await PlaylistSongPivot.query(on: app.db).count()
        #expect(count == 0)
    }

    @Test func testUpdatePlaylist() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        struct CreateBody: Codable {
            let name: String
        }
        struct UpdateBody: Codable {
            let name: String
            let description: String
        }

        // Get the created playlist ID by inspecting the response
        var playlistId: UUID?

        try await app.test(.POST, "/api/playlists", beforeRequest: { req in
            req.body = jsonBuffer(CreateBody(name: "Test"))
            req.headers.contentType = .json
        }) { res in
            let pl = try res.content.decode(PlaylistResponse.self)
            playlistId = pl.id
        }

        guard let plId = playlistId else { Issue.record("Failed to create playlist"); return }

        // Update
        try await app.test(.PUT, "/api/playlists/\(plId)", beforeRequest: { req in
            req.body = jsonBuffer(UpdateBody(name: "Updated", description: "Changed"))
            req.headers.contentType = .json
        }) { res2 in
            #expect(res2.status == .ok)
            let updated = try res2.content.decode(PlaylistResponse.self)
            #expect(updated.name == "Updated")
            #expect(updated.description == "Changed")
        }
    }

    @Test func testDeletePlaylist() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        struct CreateBody: Codable {
            let name: String
        }

        var playlistId: UUID?
        try await app.test(.POST, "/api/playlists", beforeRequest: { req in
            req.body = jsonBuffer(CreateBody(name: "ToDelete"))
            req.headers.contentType = .json
        }) { res in
            let pl = try res.content.decode(PlaylistResponse.self)
            playlistId = pl.id
        }

        guard let plId = playlistId else { Issue.record("Failed to create playlist"); return }

        // Delete
        try await app.test(.DELETE, "/api/playlists/\(plId)") { res2 in
            #expect(res2.status == .noContent)
        }

        // Verify deleted
        try await app.test(.GET, "/api/playlists") { res3 in
            let playlists = try res3.content.decode([PlaylistResponse].self)
            #expect(playlists.count == 0)
        }
    }

    @Test func testCreateAndGetArtist() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        // Create artist directly
        let artist = Artist(name: "Test Artist")
        try await artist.create(on: app.db)

        // Get via API
        try await app.test(.GET, "/api/artists?per=50") { res in
            #expect(res.status == .ok)
            let page = try res.content.decode(Page<ArtistResponse>.self)
            #expect(page.items.count == 1)
            #expect(page.items[0].name == "Test Artist")
        }
    }

    @Test func testCreateAndGetSong() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        // Create artist + song
        let artist = Artist(name: "Artist")
        try await artist.create(on: app.db)

        let song = Song(title: "Test Song", sha256: "abcdef1234567890abcdef1234567890abcdef12", fileFormat: "mp3", fileSize: 1234)
        song.$artist.id = artist.id!
        try await song.create(on: app.db)

        // Get song list
        try await app.test(.GET, "/api/songs") { res in
            #expect(res.status == .ok)
            let page = try res.content.decode(Page<SongResponse>.self)
            #expect(page.items.count == 1)
            #expect(page.items[0].title == "Test Song")
            #expect(page.items[0].fileFormat == "mp3")
            #expect(page.items[0].playStrategy == "directFile")
            #expect(page.items[0].artist != nil)
            #expect(page.items[0].artist?.name == "Artist")
        }
    }

    @Test func testSongSearch() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        // Create songs
        let artist = Artist(name: "Test Band")
        try await artist.create(on: app.db)

        let song1 = Song(title: "Rock Anthem", sha256: "aaaabbbbccccddddeeeeffff0000111122223333", fileFormat: "mp3", fileSize: 100)
        song1.$artist.id = artist.id!
        try await song1.create(on: app.db)

        let song2 = Song(title: "Jazz Vibes", sha256: "bbbbccccddddeeeeffff00001111222233334444", fileFormat: "mp3", fileSize: 200)
        song2.$artist.id = artist.id!
        try await song2.create(on: app.db)

        // Search by title
        try await app.test(.GET, "/api/songs/search?q=rock") { res in
            #expect(res.status == .ok)
            let songs = try res.content.decode([SongResponse].self)
            #expect(songs.count == 1)
            #expect(songs[0].title == "Rock Anthem")
        }

        // Search by artist
        try await app.test(.GET, "/api/songs/search?q=band") { res in
            #expect(res.status == .ok)
            let songs = try res.content.decode([SongResponse].self)
            #expect(songs.count == 2)
        }

        // Search with no results
        try await app.test(.GET, "/api/songs/search?q=nonexistent") { res in
            #expect(res.status == .ok)
            let songs = try res.content.decode([SongResponse].self)
            #expect(songs.count == 0)
        }

        // Empty query
        try await app.test(.GET, "/api/songs/search?q=") { res in
            #expect(res.status == .ok)
            let songs = try res.content.decode([SongResponse].self)
            #expect(songs.count == 0)
        }
    }

    @Test func testAddAndRemovePlaylistSongs() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        struct CreateBody: Codable {
            let name: String
        }
        struct AddSongBody: Codable {
            let songId: UUID
        }

        // Create artist, songs
        let artist = Artist(name: "Artist")
        try await artist.create(on: app.db)

        let song1 = Song(title: "S1", sha256: "1111222233334444555566667777888899990000", fileFormat: "mp3", fileSize: 100)
        song1.$artist.id = artist.id!
        try await song1.create(on: app.db)

        let song2 = Song(title: "S2", sha256: "2222333344445555666677778888999900001111", fileFormat: "mp3", fileSize: 200)
        song2.$artist.id = artist.id!
        try await song2.create(on: app.db)

        // Create playlist
        var playlistId: UUID!
        try await app.test(.POST, "/api/playlists", beforeRequest: { req in
            req.body = jsonBuffer(CreateBody(name: "Test PL"))
            req.headers.contentType = .json
        }) { res in
            let pl = try res.content.decode(PlaylistResponse.self)
            playlistId = pl.id
        }

        // Add song1
        try await app.test(.POST, "/api/playlists/\(playlistId!)/songs", beforeRequest: { req in
            req.body = jsonBuffer(AddSongBody(songId: song1.id!))
            req.headers.contentType = .json
        }) { res in
            #expect(res.status == .created)
        }

        // Add song2
        try await app.test(.POST, "/api/playlists/\(playlistId!)/songs", beforeRequest: { req in
            req.body = jsonBuffer(AddSongBody(songId: song2.id!))
            req.headers.contentType = .json
        }) { res in
            #expect(res.status == .created)
        }

        // Get playlist should have 2 songs
        try await app.test(.GET, "/api/playlists/\(playlistId!)") { res in
            #expect(res.status == .ok)
            let pl = try res.content.decode(PlaylistResponse.self)
            #expect(pl.songs?.count == 2)
        }

        // Remove song1
        try await app.test(.DELETE, "/api/playlists/\(playlistId!)/songs/\(song1.id!)") { res in
            #expect(res.status == .noContent)
        }

        // Verify only 1 song left
        try await app.test(.GET, "/api/playlists/\(playlistId!)") { res in
            let pl = try res.content.decode(PlaylistResponse.self)
            #expect(pl.songs?.count == 1)
            #expect(pl.songs?.first?.title == "S2")
        }
    }

    @Test func testNotFoundError() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        let fakeId = "00000000-0000-0000-0000-000000000000"

        try await app.test(.GET, "/api/songs/\(fakeId)") { res in
            #expect(res.status == .notFound)
        }

        try await app.test(.GET, "/api/artists/\(fakeId)") { res in
            #expect(res.status == .notFound)
        }

        try await app.test(.GET, "/api/v1/ws") { res in
            #expect(res.status == .notFound)
            let error = try res.content.decode(AdminAPIErrorResponse.self)
            #expect(error.error == "notFound")
            #expect(error.reason == "Not Found")
            #expect(error.code == 404)
        }
    }

    // MARK: - Health Endpoint

    @Test func testHealthEndpointReturnsReady() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        // 创建 CAS 目录以保证健康检查通过
        try FileManager.default.createDirectory(atPath: app.casStorage.root, withIntermediateDirectories: true)

        try await app.test(.GET, "/api/health") { res in
            #expect(res.status == .ok)
            let health = try res.content.decode(HealthResponse.self)
            #expect(health.status == "ready")
            #expect(health.version == AppVersion.current)
            #expect(health.commit == "unknown")
            #expect(health.database == "healthy")
            #expect(health.cas == "healthy")
            #expect(health.adminApi == "enabled") // createTestApp 配置了管理令牌
        }
    }

    @Test func testHealthEndpointReturnsDegradedWhenCasUnavailable() async throws {
        let app = try await Application.make(.testing)
        defer { scheduleShutdown(app) }
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateArtist())
        app.migrations.add(CreateAlbum())
        app.migrations.add(CreateSong())
        app.migrations.add(CreatePlaylist())
        app.migrations.add(CreatePlaylistSongPivot())
        try routes(app)
        // CAS 指向不存在的目录
        app.casStorage = CasStorageService(root: NSTemporaryDirectory() + "cas-nonexistent-\(UUID().uuidString)")
        try await app.autoMigrate()

        try await app.test(.GET, "/api/health") { res in
            #expect(res.status == .serviceUnavailable)
            let health = try res.content.decode(HealthResponse.self)
            #expect(health.status == "degraded")
            #expect(health.database == "healthy")
            #expect(health.cas == "unhealthy")
            #expect(health.adminApi == "disabled") // 该测试 app 未配置管理令牌
        }
    }

    @Test func testOpenAPIEndpoint() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        try await app.test(.GET, "/api/openapi.json") { res in
            #expect(res.status == .ok)
            #expect(res.headers.contentType == .json)
            let body = try JSONSerialization.jsonObject(with: res.body) as? [String: Any]
            #expect(body?["openapi"] as? String == "3.0.3")
            #expect(body?["paths"] != nil)

            // R01: info.version 来自 AppVersion，不应是旧硬编码值
            let info = body?["info"] as? [String: Any]
            let version = info?["version"] as? String
            #expect(version != nil)
            #expect(version != "1.1.0")
            #expect(version == AppVersion.current, "OpenAPI version should match AppVersion.current")

            let paths = body?["paths"] as? [String: Any]
            let songPath = paths?["/api/songs/{id}"] as? [String: Any]
            let delete = songPath?["delete"] as? [String: Any]
            let deleteSecurity = delete?["security"] as? [[String: [String]]]
            #expect(deleteSecurity == [["AdminBearer": []]])
            let deleteResponses = delete?["responses"] as? [String: [String: Any]]
            #expect(deleteResponses?["401"] != nil)
            #expect(deleteResponses?["503"] != nil)
        }
    }

    // MARK: - Artist Endpoints

    @Test func testArtistDetailWithSongCount() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        let artist = Artist(name: "Detail Artist")
        try await artist.create(on: app.db)

        let song1 = Song(title: "S1", sha256: "33334444555566667777888899990000aaaa1111", fileFormat: "mp3", fileSize: 100)
        song1.$artist.id = artist.id!
        try await song1.create(on: app.db)

        let song2 = Song(title: "S2", sha256: "4444555566667777888899990000aaaa1111bbbb", fileFormat: "mp3", fileSize: 200)
        song2.$artist.id = artist.id!
        try await song2.create(on: app.db)

        try await app.test(.GET, "/api/artists/\(artist.id!)") { res in
            #expect(res.status == .ok)
            let detail = try res.content.decode(ArtistResponse.self)
            #expect(detail.name == "Detail Artist")
            #expect(detail.songCount == 2)
        }

        try await app.test(.GET, "/api/artists/\(artist.id!)/songs") { res in
            #expect(res.status == .ok)
            let page = try res.content.decode(Page<SongResponse>.self)
            #expect(page.items.count == 2)
        }
    }

    // MARK: - Delete Song

    @Test func testDeleteSong() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        let artist = Artist(name: "A")
        try await artist.create(on: app.db)

        let song = Song(title: "Delete Me", sha256: "555566667777888899990000aaaa1111bbbb2222", fileFormat: "mp3", fileSize: 100)
        song.$artist.id = artist.id!
        try await song.create(on: app.db)

        try await app.test(.DELETE, "/api/songs/\(song.id!)", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
        }) { res in
            #expect(res.status == .noContent)
        }

        try await app.test(.GET, "/api/songs") { res in
            let page = try res.content.decode(Page<SongResponse>.self)
            #expect(page.items.count == 0)
        }
    }

    @Test func testSongFormatSummaryAndEmptyLibrary() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        try await app.test(.GET, "/api/songs/formats") { response in
            #expect(response.status == .ok)
            let summary = try response.content.decode(SongController.FormatSummary.self)
            #expect(summary.total == 0)
            #expect(summary.formats.isEmpty)
        }

        for (index, format) in ["ym", "YM", "mp3", "custom"].enumerated() {
            let song = Song(
                title: "Format \(index)",
                sha256: "format-summary-\(String(format: "%049d", index))",
                fileFormat: format,
                fileSize: 100
            )
            try await song.create(on: app.db)
        }

        try await app.test(.GET, "/api/songs/formats") { response in
            let summary = try response.content.decode(SongController.FormatSummary.self)
            #expect(summary.total == 4)
            #expect(Dictionary(uniqueKeysWithValues: summary.formats.map { ($0.format, $0.count) }) == ["custom": 1, "mp3": 1, "ym": 2])
        }
    }

    @Test func testSongSearchCanFilterByFormat() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        let artist = Artist(name: "Demo Artist")
        try await artist.create(on: app.db)
        for (index, format) in ["ym", "mp3"].enumerated() {
            let song = Song(title: "Shared title", sha256: "search-format-\(String(format: "%050d", index))", fileFormat: format, fileSize: 100)
            song.$artist.id = artist.id!
            try await song.create(on: app.db)
        }

        try await app.test(.GET, "/api/songs/search?q=shared&format=ym") { response in
            #expect(response.status == .ok)
            let songs = try response.content.decode([SongResponse].self)
            #expect(songs.map(\.fileFormat) == ["ym"])
        }
    }

    @Test func testSongSearchEagerLoadsOptionalArtistAndAlbum() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        let artist = Artist(name: "Bounded Artist")
        try await artist.create(on: app.db)
        let album = Album(artistId: artist.id!, title: "Bounded Album")
        try await album.create(on: app.db)

        let related = Song(
            title: "Bounded related",
            sha256: "search-eager-related-00000000000000000000000000000",
            fileFormat: "mp3",
            fileSize: 100
        )
        related.$artist.id = artist.id!
        related.$album.id = album.id!
        try await related.create(on: app.db)

        let standalone = Song(
            title: "Bounded standalone",
            sha256: "search-eager-standalone-0000000000000000000000000",
            fileFormat: "mp3",
            fileSize: 100
        )
        try await standalone.create(on: app.db)

        try await app.test(.GET, "/api/songs/search?q=bounded") { response in
            #expect(response.status == .ok)
            let songs = try response.content.decode([SongResponse].self)
            #expect(songs.count == 2)
            let byTitle = Dictionary(uniqueKeysWithValues: songs.map { ($0.title, $0) })
            #expect(byTitle["Bounded related"]?.artist?.name == "Bounded Artist")
            #expect(byTitle["Bounded related"]?.album?.title == "Bounded Album")
            #expect(byTitle["Bounded standalone"]?.artist == nil)
            #expect(byTitle["Bounded standalone"]?.album == nil)
        }

        try await app.test(.GET, "/api/songs/search?q=artist") { response in
            let songs = try response.content.decode([SongResponse].self)
            #expect(songs.map(\.title) == ["Bounded related"])
            #expect(songs[0].artist?.name == "Bounded Artist")
        }

        let quoted = Song(
            title: "Coder's Theme",
            sha256: "search-bound-quote-0000000000000000000000000000000",
            fileFormat: "mp3",
            fileSize: 100
        )
        try await quoted.create(on: app.db)
        try await app.test(.GET, "/api/songs/search?q=coder%27s") { response in
            #expect(response.status == .ok)
            let decoded = try response.content.decode([SongResponse].self).map(\.title)
            #expect(decoded == ["Coder's Theme"])
        }
        try await app.test(.GET, "/api/songs/search?q=%27%20OR%201%3D1%20--") { response in
            #expect(response.status == .ok)
            let decoded = try response.content.decode([SongResponse].self)
            #expect(decoded.isEmpty)
        }
    }

    @Test func testSongListAndSearchDoNotBackfillMissingDuration() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        let song = Song(
            title: "Duration remains missing",
            sha256: "duration-not-backfilled-0000000000000000000000000000",
            fileFormat: "wav",
            fileSize: 48,
            duration: nil
        )
        try await song.create(on: app.db)

        let path = app.casStorage.resolve(sha256: song.sha256, format: song.fileFormat)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try PCMData(samples: Data([0x00, 0x00, 0x00, 0x00])).encodeWAV()
            .write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: app.casStorage.root) }

        try await app.test(.GET, "/api/songs") { response in
            #expect(response.status == .ok)
            let page = try response.content.decode(Page<SongResponse>.self)
            #expect(page.items.count == 1)
            #expect(page.items[0].duration == nil)
        }

        try await app.test(.GET, "/api/songs/search?q=duration") { response in
            #expect(response.status == .ok)
            let songs = try response.content.decode([SongResponse].self)
            #expect(songs.count == 1)
            #expect(songs[0].duration == nil)
        }

        let persisted = try await Song.find(song.id!, on: app.db)
        #expect(persisted?.duration == nil)
    }

    @Test func testDurationBackfillIsDryRunSafeAndToleratesMissingCASFiles() async throws {
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
            #expect(dryRun.selected == 2)
            #expect(dryRun.updated == 0)
            let durationAfterDryRun = try await Song.find(validSong.id!, on: app.db)?.duration
            #expect(durationAfterDryRun == nil)

            let firstRun = try await service.run(options: .init(batchSize: 2, concurrency: 2))
            #expect(firstRun.selected == 2)
            #expect(firstRun.updated == 1)
            #expect(firstRun.missingFiles == 1)
            #expect(firstRun.probeFailures == 0)
            let validDuration = try await Song.find(validSong.id!, on: app.db)?.duration
            #expect(validDuration != nil)
            #expect(abs(validDuration! - 1) < 0.01)
            let missingDuration = try await Song.find(missingSong.id!, on: app.db)?.duration
            #expect(missingDuration == nil)

            let rerun = try await service.run(options: .init(batchSize: 2, concurrency: 1))
            #expect(rerun.selected == 1)
            #expect(rerun.updated == 0)
            #expect(rerun.missingFiles == 1)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test func testSongListIndexMigrationCreatesAndRevertsStableIndexes() async throws {
        let app = try await createAsyncTestApp()
        struct IndexRow: Decodable {
            let name: String
        }

        do {
            let sql = try #require(app.db as? any SQLDatabase)
            func indexNames() async throws -> Set<String> {
                let rows = try await sql.raw(
                    "SELECT name FROM sqlite_master " +
                    "WHERE type = 'index' AND name LIKE 'idx_songs_%'"
                ).all(decoding: IndexRow.self)
                return Set(rows.map(\.name))
            }

            let createdNames = try await indexNames()
            #expect(createdNames == [
                CreateSongListIndexes.createdIndex,
                CreateSongListIndexes.formatIndex,
            ])
            try await CreateSongListIndexes().revert(on: app.db)
            let revertedNames = try await indexNames()
            #expect(revertedNames.isEmpty)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test func testCasStorageHashesAndCopiesSourceFile() async throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cas-store-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let source = temporaryRoot.appendingPathComponent("source.ym")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try Data("OrzMusic\n".utf8).write(to: source)

        let cas = CasStorageService(root: temporaryRoot.appendingPathComponent("cas").path)
        let stored = try await cas.store(sourcePath: source.path)

        #expect(stored.sha256 == "9acb24a3dd4c066176e619bb6441eee64f727c62372631e6474f40c7f72947e7")
        #expect(stored.ext == "ym")
        #expect(stored.fileSize == 9)
        #expect(cas.contains(sha256: stored.sha256, format: stored.ext))
        let destination = URL(fileURLWithPath: cas.resolve(sha256: stored.sha256, format: stored.ext))
        let data = try Data(contentsOf: destination)
        #expect(data == Data("OrzMusic\n".utf8))
    }

    @Test func testScannerUsesFilenameArtistWhenScanningSourceDirectoryRoot() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }
        let importer = MusicImportService(cas: app.casStorage, db: app.db)

        let metadata = importer.parseMetadata(
            relativePath: "iOTA - ACDSee Pro 5.3 build 168 crk.v2m",
            fileName: "iOTA - ACDSee Pro 5.3 build 168 crk.v2m"
        )

        #expect(metadata.artistName == "iOTA")
        #expect(metadata.songTitle == "ACDSee Pro 5.3 build 168")
    }

    @Test func testScannerOnlyFingerprintsContainerAudioFormats() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }
        let importer = MusicImportService(cas: app.casStorage, db: app.db)

        #expect(importer.shouldGenerateAudioFingerprint(format: .mp3))
        #expect(importer.shouldGenerateAudioFingerprint(format: .ogg))
        #expect(importer.shouldGenerateAudioFingerprint(format: .wav))

        #expect(!importer.shouldGenerateAudioFingerprint(format: .xm))
        #expect(!importer.shouldGenerateAudioFingerprint(format: .mod))
        #expect(!importer.shouldGenerateAudioFingerprint(format: .v2m))
        #expect(!importer.shouldGenerateAudioFingerprint(format: .sc68))
        #expect(!importer.shouldGenerateAudioFingerprint(format: .ym))
    }

    @Test func testMusicImportServiceCreatesMetadataAndReturnsDuplicate() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("music-import-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.v2m")
        try Data("same-module-content".utf8).write(to: source)

        let app = try await createAsyncTestApp()
        let cas = CasStorageService(root: root.appendingPathComponent("cas").path)
        let importer = MusicImportService(cas: cas, db: app.db)

        do {
            let first = try await importer.importFile(
                sourcePath: source.path,
                relativePath: "Demo Group/iOTA - Product keygen.v2m"
            )
            guard case .created(let created) = first else {
                Issue.record("Expected a newly created song"); return
            }
            #expect(created.title == "Product")
            #expect(created.audioFingerprint == nil)

            let artist = try await created.$artist.get(on: app.db)
            #expect(artist?.name == "iOTA")

            let second = try await importer.importFile(
                sourcePath: source.path,
                relativePath: "Different/Other Title.v2m"
            )
            guard case .duplicate(let duplicate) = second else {
                Issue.record("Expected duplicate result"); return
            }
            #expect(duplicate.id == created.id)
            let songCount = try await Song.query(on: app.db).count()
            #expect(songCount == 1)
            #expect(cas.contains(sha256: created.sha256, format: "v2m"))
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test func testMusicImportServiceExplicitMetadataOverridesPathInference() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("music-import-explicit-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.v2m")
        try Data("explicit-module-content".utf8).write(to: source)

        let app = try await createAsyncTestApp()
        let importer = MusicImportService(
            cas: CasStorageService(root: root.appendingPathComponent("cas").path),
            db: app.db
        )

        do {
            let result = try await importer.importFile(
                sourcePath: source.path,
                relativePath: "Path Artist/Path Title.v2m",
                artist: " Explicit Artist ",
                title: " Explicit Title "
            )
            guard case .created(let song) = result else {
                Issue.record("Expected a newly created song"); return
            }
            #expect(song.title == "Explicit Title")
            let artist = try await song.$artist.get(on: app.db)
            #expect(artist?.name == "Explicit Artist")
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test func testMusicImportServiceConcurrentSameContentProducesOneSong() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("music-import-race-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstSource = root.appendingPathComponent("first.v2m")
        let secondSource = root.appendingPathComponent("second.v2m")
        let bytes = Data("concurrent-module-content".utf8)
        try bytes.write(to: firstSource)
        try bytes.write(to: secondSource)

        let app = try await createAsyncTestApp()
        let importer = MusicImportService(
            cas: CasStorageService(root: root.appendingPathComponent("cas").path),
            db: app.db
        )

        do {
            async let first = importer.importFile(
                sourcePath: firstSource.path,
                relativePath: "Artist/First.v2m"
            )
            async let second = importer.importFile(
                sourcePath: secondSource.path,
                relativePath: "Artist/Second.v2m"
            )
            let results = try await [first, second]

            let createdCount = results.reduce(into: 0) { count, result in
                if case .created = result { count += 1 }
            }
            let duplicateCount = results.reduce(into: 0) { count, result in
                if case .duplicate = result { count += 1 }
            }
            #expect(createdCount == 1)
            #expect(duplicateCount == 1)
            let songCount = try await Song.query(on: app.db).count()
            #expect(songCount == 1)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test func testMusicImportDuplicateWithDifferentExtensionDoesNotCreateOrphanCASFile() async throws {
        let app = try await createAsyncTestApp()
        defer { scheduleShutdown(app) }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cross-extension-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("same.v2m")
        let second = root.appendingPathComponent("same.mod")
        let bytes = Data("identical-audio-content".utf8)
        try bytes.write(to: first)
        try bytes.write(to: second)

        let importer = MusicImportService(cas: app.casStorage, db: app.db)
        guard case .created = try await importer.importFile(sourcePath: first.path) else {
            Issue.record("First import should create a song"); return
        }
        guard case .duplicate = try await importer.importFile(sourcePath: second.path) else {
            Issue.record("Second import should be a duplicate"); return
        }

        let casFiles = FileManager.default.enumerator(atPath: app.casStorage.root)?
            .compactMap { $0 as? String }
            .filter { !$0.hasSuffix("/") } ?? []
        #expect(casFiles.filter { $0.hasSuffix(".v2m") }.count == 1)
        #expect(casFiles.filter { $0.hasSuffix(".mod") }.count == 0)
        let songCount = try await Song.query(on: app.db).count()
        #expect(songCount == 1)
    }

    @Test func testMusicImportRemovesNewCASObjectWhenDatabaseWorkFails() async throws {
        struct InjectedFailure: Error {}

        let app = try await createAsyncTestApp()
        defer { scheduleShutdown(app) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-import-\(UUID().uuidString).v2m")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("failure-cleanup-content".utf8).write(to: source)

        let importer = MusicImportService(
            cas: app.casStorage,
            db: app.db,
            afterCASStore: { _ in throw InjectedFailure() }
        )
        do {
            _ = try await importer.importFile(sourcePath: source.path)
            Issue.record("Injected failure should escape the importer")
        } catch is InjectedFailure {
            // Expected.
        }

        let songCount = try await Song.query(on: app.db).count()
        #expect(songCount == 0)
        let casFiles = FileManager.default.enumerator(atPath: app.casStorage.root)?
            .compactMap { $0 as? String }
            .filter { $0.contains(".") } ?? []
        #expect(casFiles.isEmpty)
    }

    @Test func testScannerRejectsUnavailableRoot() async throws {
        let missingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-scan-root-\(UUID().uuidString)")
        let app = try await createTestApp(scanRoot: missingRoot.path)
        defer { scheduleShutdown(app) }

        try await app.test(.POST, "/api/scan", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
        }) { response in
            #expect(response.status == .serviceUnavailable)
            let body = try response.content.decode(AdminAPIErrorResponse.self)
            #expect(body.error == "scan_root_unavailable")
        }
    }

    @Test func testScannerScansConfiguredRootWithoutRequestPaths() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scan-root-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("module-audio".utf8).write(to: root.appendingPathComponent("Artist - Song.v2m"))

        let app = try await createTestApp(scanRoot: root.path)
        defer { scheduleShutdown(app) }

        try await app.test(.POST, "/api/scan", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
            request.headers.contentType = .json
            request.body = jsonBuffer(["sources": ["/"]])
        }) { response in
            #expect(response.status == .ok)
            let result = try response.content.decode(MusicScannerService.ScanResult.self)
            #expect(result.totalScanned == 1)
            #expect(result.songsCreated == 1)
            #expect(result.duplicatesSkipped == 0)
            #expect(result.failedFiles == 0)
        }

        let count = try await Song.query(on: app.db).count()
        #expect(count == 1)
    }

    @Test func testScannerSkipsSymbolicLinksOutsideConfiguredRoot() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scan-symlink-test-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: root.appendingPathComponent("inside.v2m"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("outside.v2m"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escaped.v2m"),
            withDestinationURL: outside.appendingPathComponent("outside.v2m")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escaped-directory"),
            withDestinationURL: outside
        )

        let app = try await createTestApp(scanRoot: root.path)
        defer { scheduleShutdown(app) }

        try await app.test(.POST, "/api/scan", beforeRequest: { request in
            request.headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
        }) { response in
            #expect(response.status == .ok)
            let result = try response.content.decode(MusicScannerService.ScanResult.self)
            #expect(result.totalScanned == 1)
            #expect(result.songsCreated == 1)
            #expect(result.failedFiles == 0)
        }

        let count = try await Song.query(on: app.db).count()
        #expect(count == 1)
    }

    @Test func testScannerRejectsCandidateReplacedAfterSnapshotCopy() async throws {
        let app = try await createAsyncTestApp()
        defer { scheduleShutdown(app) }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-snapshot-race-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside.v2m")
        let candidate = root.appendingPathComponent("candidate.v2m")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("inside-content".utf8).write(to: candidate)
        try Data("outside-content".utf8).write(to: outside)

        let scanner = MusicScannerService(
            sourceRoot: root.path,
            cas: app.casStorage,
            db: app.db,
            snapshotDidCopy: { source in
                try! FileManager.default.removeItem(at: source)
                try! FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
            }
        )
        let result = try await scanner.scan()

        #expect(result.totalScanned == 1)
        #expect(result.songsCreated == 0)
        #expect(result.failedFiles == 1)
        let songCount = try await Song.query(on: app.db).count()
        #expect(songCount == 0)
        let casFiles = FileManager.default.enumerator(atPath: app.casStorage.root)?
            .compactMap { $0 as? String }
            .filter { $0.contains(".") } ?? []
        #expect(casFiles.isEmpty)
    }

    @Test func testScannerRejectsConcurrentScanWithStableErrorCode() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scan-lock-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let app = try await createAsyncTestApp(scanRoot: root.path)

        let acquired = await ScanExecutionCoordinator.shared.tryBegin()
        #expect(acquired)

        do {
            let response = try await app.sendRequest(.POST, "/api/scan", beforeRequest: { request in
                await Task.yield()
                request.headers.replaceOrAdd(name: .authorization, value: "Bearer test-admin-token")
            })
            #expect(response.status == .conflict)
            let body = try response.content.decode(AdminAPIErrorResponse.self)
            #expect(body.error == "scan_already_running")
            await ScanExecutionCoordinator.shared.finish()
            try await app.asyncShutdown()
        } catch {
            await ScanExecutionCoordinator.shared.finish()
            try? await app.asyncShutdown()
            throw error
        }
    }

    // MARK: - Playlist Reorder

    @Test func testPlaylistReorder() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

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
        try await artist.create(on: app.db)

        var songs: [Song] = []
        for i in 1...3 {
            let s = Song(title: "S\(i)", sha256: "song-hash-\(String(format: "%040x", i))", fileFormat: "mp3", fileSize: i * 100)
            s.$artist.id = artist.id!
            try await s.create(on: app.db)
        songs.append(s)
        }

        // Create playlist
        var playlistId: UUID!
        try await app.test(.POST, "/api/playlists", beforeRequest: { req in
            req.body = jsonBuffer(CreateBody(name: "Reorder PL"))
            req.headers.contentType = .json
        }) { res in
            let pl = try res.content.decode(PlaylistResponse.self)
            playlistId = pl.id
        }

        // Add songs in order S1, S2, S3
        for song in songs {
            try await app.test(.POST, "/api/playlists/\(playlistId!)/songs", beforeRequest: { req in
                req.body = jsonBuffer(AddSongBody(songId: song.id!))
                req.headers.contentType = .json
            }) { res in
                #expect(res.status == .created)
            }
        }

        // Reorder: S3, S1, S2
        let reorderIds = [songs[2].id!, songs[0].id!, songs[1].id!]
        try await app.test(.PUT, "/api/playlists/\(playlistId!)/songs/reorder", beforeRequest: { req in
            req.body = jsonBuffer(ReorderBody(songIds: reorderIds))
            req.headers.contentType = .json
        }) { res in
            #expect(res.status == .ok)
        }

        // Verify order
        try await app.test(.GET, "/api/playlists/\(playlistId!)") { res in
            let pl = try res.content.decode(PlaylistResponse.self)
            #expect(pl.songs?.count == 3)
            #expect(pl.songs?[0].title == "S3")
            #expect(pl.songs?[1].title == "S1")
            #expect(pl.songs?[2].title == "S2")
        }
    }

    // MARK: - Song Location

    @Test func testSongLocationFirstSong() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        var songs: [Song] = []
        for i in 1...5 {
            let s = Song(id: orderedUUID(i), title: "L\(i)", sha256: "loc-hash-\(String(format: "%049d", i))", fileFormat: "mp3", fileSize: i * 100)
            try await s.create(on: app.db)
        songs.append(s)
        }

        // The last-created song should be first (index 0) in createdAt DESC order
        let lastId = songs.last!.id!
        try await app.test(.GET, "/api/songs/\(lastId)/location") { res in
            #expect(res.status == .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            #expect(loc.songId == lastId)
            #expect(loc.index == 0)
            #expect(loc.page == 1)
            #expect(loc.per == 50)
        }
    }

    @Test func testSongLocationPerPageBoundary() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        // Create 15 songs
        var songs: [Song] = []
        for i in 1...15 {
            let s = Song(id: orderedUUID(i), title: "B\(i)", sha256: "loc-b-\(String(format: "%048d", i))", fileFormat: "mp3", fileSize: i * 100)
            try await s.create(on: app.db)
        songs.append(s)
        }

        // per=5, 5th from newest = index 4 → page 1, 6th from newest = index 5 → page 2
        let songIdx4 = songs[songs.count - 5].id!
        let songIdx5 = songs[songs.count - 6].id!

        try await app.test(.GET, "/api/songs/\(songIdx4)/location?per=5") { res in
            #expect(res.status == .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            #expect(loc.index == 4)
            #expect(loc.page == 1)
            #expect(loc.per == 5)
        }

        try await app.test(.GET, "/api/songs/\(songIdx5)/location?per=5") { res in
            #expect(res.status == .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            #expect(loc.index == 5)
            #expect(loc.page == 2)
            #expect(loc.per == 5)
        }
    }

    @Test func testSongLocationLastPage() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        // Create 12 songs
        var songs: [Song] = []
        for i in 1...12 {
            let s = Song(id: orderedUUID(i), title: "LP\(i)", sha256: "loc-lp-\(String(format: "%048d", i))", fileFormat: "mp3", fileSize: i * 100)
            try await s.create(on: app.db)
        songs.append(s)
        }

        // per=5: indexes 0-4 → page 1, 5-9 → page 2, 10-11 → page 3
        // First-created song → last in sort (index 11) → page 3
        let firstSong = songs.first!.id!
        try await app.test(.GET, "/api/songs/\(firstSong)/location?per=5") { res in
            #expect(res.status == .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            #expect(loc.index == 11)
            #expect(loc.page == 3)
            #expect(loc.per == 5)
        }
    }

    @Test func testSongLocationStableOrder() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        // Create 3 songs with no time gap (same createdAt timestamp)
        // Fluent's @Timestamp uses second precision for .create,
        // so songs created within the same second get the same createdAt.
        // The id DESC tiebreaker ensures stable ordering.
        var songs: [Song] = []
        for i in 1...3 {
            let s = Song(id: orderedUUID(i), title: "Stable\(i)", sha256: "loc-stable-\(String(format: "%048d", i))", fileFormat: "mp3", fileSize: i * 100)
            try await s.create(on: app.db)
        songs.append(s)
        }

        // In createdAt DESC, id DESC order, the last-created song is first
        let lastCreated = songs.last!.id!
        try await app.test(.GET, "/api/songs/\(lastCreated)/location") { res in
            #expect(res.status == .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            #expect(loc.index == 0)
        }
    }

    @Test func testSongLocationUnknownId() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        let fakeId = "00000000-0000-0000-0000-000000000000"
        try await app.test(.GET, "/api/songs/\(fakeId)/location") { res in
            #expect(res.status == .notFound)
        }
    }

    @Test func testSongLocationInvalidPerParams() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        let song = Song(title: "PerTest", sha256: "loc-per-test-\(String(format: "%048d", 1))", fileFormat: "mp3", fileSize: 100)
        try await song.create(on: app.db)
        guard let songId = song.id else { Issue.record("no id"); return }

        // per=0
        try await app.test(.GET, "/api/songs/\(songId)/location?per=0") { res in
            #expect(res.status == .badRequest)
        }

        // per=101
        try await app.test(.GET, "/api/songs/\(songId)/location?per=101") { res in
            #expect(res.status == .badRequest)
        }

        // non-numeric per
        try await app.test(.GET, "/api/songs/\(songId)/location?per=abc") { res in
            #expect(res.status == .badRequest)
        }

        // negative per
        try await app.test(.GET, "/api/songs/\(songId)/location?per=-1") { res in
            #expect(res.status == .badRequest)
        }
    }

    @Test func testSongLocationResponseMatchesIndexApi() async throws {
        let app = try await createTestApp()
        defer { scheduleShutdown(app) }

        // Create 7 songs
        var songs: [Song] = []
        for i in 1...7 {
            let s = Song(id: orderedUUID(i), title: "Match\(i)", sha256: "loc-match-\(String(format: "%048d", i))", fileFormat: "mp3", fileSize: i * 100)
            try await s.create(on: app.db)
        songs.append(s)
        }

        // per=3: 4th-from-newest → index 3, page 2
        let midIdx = songs[songs.count - 4].id!
        try await app.test(.GET, "/api/songs/\(midIdx)/location?per=3") { res in
            #expect(res.status == .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            #expect(loc.index == 3)
            #expect(loc.page == 2)
            #expect(loc.per == 3)

            // Verify that page 2 of /api/songs contains this song
            try await app.test(.GET, "/api/songs?page=2&per=3") { pageRes in
                #expect(pageRes.status == .ok)
                let page = try pageRes.content.decode(Page<SongResponse>.self)
                let found = page.items.contains(where: { $0.id == midIdx })
                #expect(found)
            }
        }

        // First song in sort (newest) = index 0, page 1
        let firstId = songs.last!.id!
        try await app.test(.GET, "/api/songs/\(firstId)/location?per=3") { res in
            #expect(res.status == .ok)
            let loc = try res.content.decode(SongLocationResponse.self)
            #expect(loc.index == 0)
            #expect(loc.page == 1)

            try await app.test(.GET, "/api/songs?page=1&per=3") { pageRes in
                #expect(pageRes.status == .ok)
                let page = try pageRes.content.decode(Page<SongResponse>.self)
                let found = page.items.contains(where: { $0.id == firstId })
                #expect(found)
            }
        }
    }
}
