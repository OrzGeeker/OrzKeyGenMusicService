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

    /// GET /api/songs/search?q= — 搜索（歌曲名 + 艺术家名）
    @Sendable
    func search(req: Request) async throws -> [SongResponse] {
        guard let rawQuery = req.query[String.self, at: "q"], !rawQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }

        // 安全过滤：移除可能破坏 SQL 的特殊字符，保留字母、数字、空格和基本标点
        let safeQuery = rawQuery.replacingOccurrences(of: "'", with: "''")
            .trimmingCharacters(in: .whitespaces)

        guard !safeQuery.isEmpty else { return [] }

        // 同时搜索歌曲标题和艺术家名称（使用 LOWER 兼容 PostgreSQL 和 SQLite）
        let songs = try await Song.query(on: req.db)
            .join(Artist.self, on: \Artist.$id == \Song.$artist.$id, method: .left)
            .filter(.sql(unsafeRaw: "LOWER(title) LIKE '%\(safeQuery.lowercased())%' OR LOWER(\"artists\".\"name\") LIKE '%\(safeQuery.lowercased())%'"))
            .limit(50)
            .all()

        let baseURL = baseURL(from: req)
        // 预加载关联
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

        let fullPath = resolveFilePath(for: song, req: req)

        // YM 文件：优先提供构建时解压的 raw YM6 版本
        if let format = AudioFormat(rawValue: song.fileFormat), format == .ym {
            let rawPath = resolveYmRawPath(for: song, req: req)
            if FileManager.default.fileExists(atPath: rawPath) {
                return try await req.fileio.asyncStreamFile(at: rawPath)
            }
        }

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
            // YM 文件：优先提供构建时解压的 raw YM6 版本（保持 LHa 原始归档不变）
            if format == .ym {
                let rawPath = resolveYmRawPath(for: song, req: req)
                if FileManager.default.fileExists(atPath: rawPath) {
                    return try await req.fileio.asyncStreamFile(at: rawPath)
                }
            }
            return try await req.fileio.asyncStreamFile(at: path)

        case .serverDecode(let path, let fmt):
            let wav = try await engine.decodeToWAV(filePath: path, format: fmt)
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

        let fullPath = resolveFilePath(for: song, req: req)
        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw Abort(.notFound)
        }

        return try await req.fileio.asyncStreamFile(at: fullPath)
    }

    // MARK: - Helpers

    /// 解析歌曲文件的完整磁盘路径
    ///
    /// 优先使用 MUSIC_PATH 环境变量（与扫描器一致），否则回退到 publicDirectory。
    /// 修复：扫描器与流式端点路径不匹配的问题。
    private func resolveFilePath(for song: Song, req: Request) -> String {
        let musicPath = Environment.get("MUSIC_PATH")
            ?? req.application.directory.publicDirectory
        return (musicPath as NSString).appendingPathComponent(song.filePath)
    }

    private func baseURL(from req: Request) -> String {
        "\(req.headers.first(name: "x-forwarded-proto") ?? "http")://\(req.headers.first(name: "host") ?? "localhost:8080")"
    }

    /// 构建时解压的 raw YM6 文件路径（保持原始 LHa 归档不变）
    private func resolveYmRawPath(for song: Song, req: Request) -> String {
        (req.application.directory.publicDirectory as NSString)
            .appendingPathComponent("audio/ym-raw")
            .appendingPathComponent(song.filePath)
    }
}
