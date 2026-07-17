import Foundation
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

    /// GET /api/songs — 歌曲列表（分页，支持 &format= 过滤）
    @Sendable
    func index(req: Request) async throws -> Page<SongResponse> {
        var query = Song.query(on: req.db)
            .with(\.$artist)
            .with(\.$album)
            .sort(\.$createdAt, .descending)

        if let format = req.query[String.self, at: "format"], !format.isEmpty {
            query = query.filter(\.$fileFormat == format.lowercased())
        }

        let page = try await query.paginate(for: req)

        let baseURL = baseURL(from: req)
        return .init(
            items: page.items.map { SongResponse(song: $0, baseURL: baseURL) },
            metadata: page.metadata
        )
    }

    /// GET /api/songs/search?q= — 搜索（歌曲名 + 艺术家名）
    @Sendable
    func search(req: Request) async throws -> [SongResponse] {
        guard let rawQuery = req.query[String.self, at: "q"], !rawQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }

        let safeQuery = rawQuery.replacingOccurrences(of: "'", with: "''")
            .trimmingCharacters(in: .whitespaces)

        guard !safeQuery.isEmpty else { return [] }

        let songs = try await Song.query(on: req.db)
            .join(Artist.self, on: \Artist.$id == \Song.$artist.$id, method: .left)
            .filter(.sql(unsafeRaw: "LOWER(title) LIKE '%\(safeQuery.lowercased())%' OR LOWER(\"artists\".\"name\") LIKE '%\(safeQuery.lowercased())%'"))
            .limit(50)
            .all()

        let baseURL = baseURL(from: req)
        for song in songs {
            try await song.$artist.load(on: req.db)
            try await song.$album.load(on: req.db)
        }
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

        guard let format = AudioFormat(rawValue: song.fileFormat) else {
            throw Abort(.badRequest, reason: "Unknown format: \(song.fileFormat)")
        }

        let cas = req.application.casStorage
        let fullPath = cas.resolve(sha256: song.sha256, format: song.fileFormat)

        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw CasError.fileNotFound(sha256: song.sha256, format: song.fileFormat)
        }

        let engine = AudioEngine()
        let requestedSubsong = req.query[Int.self, at: "subsong"] ?? 0
        guard requestedSubsong >= 0, requestedSubsong <= Int(Int32.max) else {
            throw Abort(.badRequest, reason: "Invalid subsong")
        }
        let subsong = requestedSubsong
        let strategy = engine.resolveStreamStrategy(filePath: fullPath, format: format)

        switch strategy {
        case .directFile(let path, let mime):
            var res = try await req.fileio.asyncStreamFile(at: path)
            res.headers.replaceOrAdd(name: .contentType, value: mime)
            return res

        case .wasmDecode(let path, _):
            return try await req.fileio.asyncStreamFile(at: path)

        case .serverDecode(let path, let fmt):
            // 尝试从转码缓存读取（避免重复 ffmpeg）
            let cachePath = try await cachedDecode(originalPath: path, sha256: song.sha256, format: fmt, subsong: subsong, cas: req.application.casStorage)
            var res = try await req.fileio.asyncStreamFile(at: cachePath)
            res.headers.replaceOrAdd(name: .contentType, value: "audio/wav")
            return res
        }
    }

    /// GET /api/songs/:id/raw — 原始文件下载
    @Sendable
    func raw(req: Request) async throws -> Response {
        guard let song = try await Song.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }

        let cas = req.application.casStorage
        let fullPath = cas.resolve(sha256: song.sha256, format: song.fileFormat)

        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw Abort(.notFound)
        }

        return try await req.fileio.asyncStreamFile(at: fullPath)
    }

    // MARK: - Helpers

    /// 服务端解码，并将结果缓存到 CAS 缓存目录
    /// 首次请求转码（AudioEngine → C 解码器 / ffmpeg），后续直接读缓存
    private func cachedDecode(originalPath: String, sha256: String, format: AudioFormat, subsong: Int, cas: CasStorageService) async throws -> String {
        let cacheDir = "\(cas.root)/.cache/wav/"
        // Version output semantics so decoder/format changes never reuse stale PCM.
        let cachePath = "\(cacheDir)\(sha256)-decoder-v3-rate-native-ch-native-sub-\(subsong).wav"

        let fm = FileManager.default
        if fm.fileExists(atPath: cachePath) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath), options: .mappedIfSafe),
               (try? WAVFile.parse(data, includeSamples: false).encoding) == .pcm {
                return cachePath
            }
            try? fm.removeItem(atPath: cachePath)
        }

        try fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        try await AudioEngine().decodeToWAVFile(
            filePath: originalPath,
            format: format,
            destinationPath: cachePath,
            subsong: subsong
        )
        return cachePath
    }

    private func baseURL(from req: Request) -> String {
        "\(req.headers.first(name: "x-forwarded-proto") ?? "http")://\(req.headers.first(name: "host") ?? "localhost:8080")"
    }
}
