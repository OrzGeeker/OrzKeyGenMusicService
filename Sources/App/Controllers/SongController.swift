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

        // YM 格式：WASM 解码器需要原始 YM6 数据（不含 LHa 压缩头）
        // 如果 CAS 存储的是 LHa 压缩版，用系统 lha 解压后再提供
        if format == .ym {
            if isLHaCompressed(at: fullPath) {
                let decompPath = try await decompressYM(fullPath, sha256: song.sha256, cas: cas)
                var res = try await req.fileio.asyncStreamFile(at: decompPath)
                res.headers.replaceOrAdd(name: .contentType, value: "audio/ym")
                return res
            }
            var res = try await req.fileio.asyncStreamFile(at: fullPath)
            res.headers.replaceOrAdd(name: .contentType, value: "audio/ym")
            return res
        }

        let engine = AudioEngine()
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
            let cachePath = try await cachedDecode(originalPath: path, sha256: song.sha256, format: fmt, cas: req.application.casStorage)
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
    private func cachedDecode(originalPath: String, sha256: String, format: AudioFormat, cas: CasStorageService) async throws -> String {
        let cacheDir = "\(cas.root)/.cache/wav/"
        let cachePath = "\(cacheDir)\(sha256).wav"

        let fm = FileManager.default
        if fm.fileExists(atPath: cachePath) {
            return cachePath
        }

        // 首次：通过 AudioEngine 解码为 PCM WAV 并缓存
        let engine = AudioEngine()
        let wavData = try await engine.decodeToWAV(filePath: originalPath, format: format)

        try queue.sync {
            try fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            try wavData.write(to: URL(fileURLWithPath: cachePath))
        }
        return cachePath
    }

    private let queue = DispatchQueue(label: "com.orzplayer.cache")

    /// 检查文件是否 LHa 压缩（以 "-lh5-" 或 "-lh6-" 头标记）
    private func isLHaCompressed(at path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 8)
        guard magic.count >= 7 else { return false }
        // LHa 头：2 字节校验 + "-lh5-" 或 "-lh6-"
        let bytes = [UInt8](magic)
        return bytes[2] == 0x2D && bytes[3] == 0x6C && bytes[4] == 0x68 &&
               (bytes[5] == 0x35 || bytes[5] == 0x36) && bytes[6] == 0x2D
    }

    /// 使用系统 lha 解压 YM 文件，结果缓存到 CAS 缓存目录
    private func decompressYM(_ path: String, sha256: String, cas: CasStorageService) async throws -> String {
        let cacheDir = "\(cas.root)/.cache/ym/"
        let cachePath = "\(cacheDir)\(sha256).ym"
        let fm = FileManager.default
        if fm.fileExists(atPath: cachePath) { return cachePath }

        let tmpDir = fm.temporaryDirectory.appendingPathComponent("orz_ym_\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/lha")
        process.arguments = ["x", path]
        process.currentDirectoryURL = tmpDir

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 { c.resume() }
                else { c.resume(throwing: AudioError.decodeFailed("lha exit \(p.terminationStatus)")) }
            }
            do { try process.run() } catch { c.resume(throwing: error) }
        }

        // 找到解压出的文件
        let contents = try fm.contentsOfDirectory(atPath: tmpDir.path)
        guard let decompFile = contents.first(where: { $0 != "." && $0 != ".." }) else {
            throw AudioError.decodeFailed("lha produced no output for YM: \(sha256)")
        }

        let decompPath = tmpDir.appendingPathComponent(decompFile).path
        try queue.sync {
            try fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: cachePath) {
                try fm.copyItem(atPath: decompPath, toPath: cachePath)
            }
        }
        return cachePath
    }

    private func baseURL(from req: Request) -> String {
        "\(req.headers.first(name: "x-forwarded-proto") ?? "http")://\(req.headers.first(name: "host") ?? "localhost:8080")"
    }
}
