import Vapor
import Fluent
import OrzAudioKit

struct SongController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let songs = routes.grouped("api", "songs")
        songs.get(use: index)
        songs.get("search", use: search)
        songs.group(":id") { song in
            song.get(use: show)
            song.get("stream", use: stream)
            song.get("raw", use: raw)
        }
    }

    /// GET /api/songs — 歌曲列表（分页）
    @Sendable
    func index(req: Request) async throws -> Page<SongResponse> {
        let page = try await Song.query(on: req.db)
            .with(\.$artist)
            .with(\.$album)
            .sort(\.$createdAt, .descending)
            .paginate(for: req)

        let baseURL = baseURL(from: req)
        return .init(
            items: page.items.map { SongResponse(song: $0, baseURL: baseURL) },
            metadata: page.metadata
        )
    }

    /// GET /api/songs/search?q= — 搜索
    @Sendable
    func search(req: Request) async throws -> [SongResponse] {
        guard let query = req.query[String.self, at: "q"], !query.isEmpty else {
            return []
        }

        let songs = try await Song.query(on: req.db)
            .filter(.sql(raw: "title ILIKE '%\(query)%'"))
            .limit(50)
            .all()

        let baseURL = baseURL(from: req)
        return songs.map { SongResponse(song: $0, baseURL: baseURL) }
    }

    /// GET /api/songs/:id — 歌曲详情
    @Sendable
    func show(req: Request) async throws -> SongResponse {
        guard let song = try await Song.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }
        try await song.$artist.load(on: req.db)
        try await song.$album.load(on: req.db)

        return SongResponse(song: song, baseURL: baseURL(from: req))
    }

    /// GET /api/songs/:id/stream — 音频流
    @Sendable
    func stream(req: Request) async throws -> Response {
        guard let song = try await Song.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }

        let publicDir = req.application.directory.publicDirectory
        let fullPath = "\(publicDir)\(song.filePath)"

        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw Abort(.notFound, reason: "Audio file not found on disk")
        }

        guard let format = AudioFormat(rawValue: song.fileFormat) else {
            throw Abort(.badRequest, reason: "Unknown format: \(song.fileFormat)")
        }

        let engine = AudioEngine()
        let strategy = engine.resolveStreamStrategy(
            filePath: fullPath,
            format: format
        )

        switch strategy {
        case .directFile(let path, _),
             .wasmDecode(let path, _):
            return req.fileio.streamFile(at: path)

        case .serverDecode(let path, let fmt):
            let wav = try engine.decodeToWAV(filePath: path, format: fmt)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "audio/wav")
            headers.add(name: "Content-Length", value: "\(wav.count)")
            return Response(status: .ok, headers: headers, body: .init(data: wav))
        }
    }

    /// GET /api/songs/:id/raw — 原始文件下载
    @Sendable
    func raw(req: Request) async throws -> Response {
        guard let song = try await Song.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }

        let fullPath = "\(req.application.directory.publicDirectory)\(song.filePath)"
        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw Abort(.notFound)
        }

        return req.fileio.streamFile(at: fullPath)
    }

    // MARK: - Helpers

    private func baseURL(from req: Request) -> String {
        "\(req.headers.first(name: "x-forwarded-proto") ?? "http")://\(req.headers.first(name: "host") ?? "localhost:8080")"
    }
}
