@testable import App
@testable import OrzAudioKit
import XCTVapor
import Fluent
import FluentSQLiteDriver

final class AppTests: XCTestCase {

    // MARK: - Test Lifecycle

    private func createTestApp() throws -> Application {
        let app = Application(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)

        // Register migrations
        app.migrations.add(CreateArtist())
        app.migrations.add(CreateAlbum())
        app.migrations.add(CreateSong())
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

    /// Helper: encode a JSON object to ByteBuffer
    private func jsonBuffer(_ value: some Encodable) -> ByteBuffer {
        let data = try! JSONEncoder().encode(value)
        return ByteBuffer(data: data)
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
        XCTAssertEqual(AudioFormat.from(fileExtension: "wav")?.playStrategy.rawValue, "directFile")
        XCTAssertEqual(AudioFormat.from(fileExtension: "flac")?.playStrategy.rawValue, "directFile")
        XCTAssertEqual(AudioFormat.from(fileExtension: "mid")?.playStrategy.rawValue, "directFile")

        // wasmDecode formats
        XCTAssertEqual(AudioFormat.from(fileExtension: "xm")?.playStrategy.rawValue, "wasmDecode")
        XCTAssertEqual(AudioFormat.from(fileExtension: "mod")?.playStrategy.rawValue, "wasmDecode")
        XCTAssertEqual(AudioFormat.from(fileExtension: "it")?.playStrategy.rawValue, "wasmDecode")
        XCTAssertEqual(AudioFormat.from(fileExtension: "s3m")?.playStrategy.rawValue, "wasmDecode")
        XCTAssertEqual(AudioFormat.from(fileExtension: "sid")?.playStrategy.rawValue, "wasmDecode")
        XCTAssertEqual(AudioFormat.from(fileExtension: "nsf")?.playStrategy.rawValue, "wasmDecode")

        // serverDecode formats
        XCTAssertEqual(AudioFormat.from(fileExtension: "bp")?.playStrategy.rawValue, "serverDecode")
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

        // serverDecode
        let bpStrategy = engine.resolveStreamStrategy(filePath: "/test.bp", format: .bp)
        if case .serverDecode(let path, let fmt) = bpStrategy {
            XCTAssertEqual(path, "/test.bp")
            XCTAssertEqual(fmt, .bp)
        } else {
            XCTFail("Expected serverDecode strategy for bp")
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

    func testOpenAPIEndpoint() throws {
        let app = try createTestApp()
        defer { app.shutdown() }

        try app.test(.GET, "/api/openapi.json") { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType, .json)
            let body = try JSONSerialization.jsonObject(with: res.body) as? [String: Any]
            XCTAssertEqual(body?["openapi"] as? String, "3.0.3")
            XCTAssertNotNil(body?["paths"])
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

        try app.test(.DELETE, "/api/songs/\(song.id!)") { res in
            XCTAssertEqual(res.status, .noContent)
        }

        try app.test(.GET, "/api/songs") { res in
            let page = try res.content.decode(Page<SongResponse>.self)
            XCTAssertEqual(page.items.count, 0)
        }
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
}
