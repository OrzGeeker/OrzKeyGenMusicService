import Foundation
import Vapor
import Fluent
import OrzAudioKit

struct SongController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let songs = routes.grouped("api", "songs")
        songs.get(use: index)
        songs.get("formats", use: formats)
        songs.get("search", use: search)
        songs.group(":id") { song in
            song.get(use: show)
            song.get("stream", use: stream)
            song.get("raw", use: raw)
        }
    }

    struct FormatCount: Content {
        let format: String
        let count: Int
    }

    struct FormatSummary: Content {
        let total: Int
        let formats: [FormatCount]
    }

    /// GET /api/songs/formats — total and per-format counts for library navigation.
    @Sendable
    func formats(req: Request) async throws -> FormatSummary {
        let values = try await Song.query(on: req.db).field(\.$fileFormat).all().map { $0.fileFormat.lowercased() }
        let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        return FormatSummary(
            total: values.count,
            formats: counts.map { FormatCount(format: $0.key, count: $0.value) }
                .sorted { $0.format < $1.format }
        )
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
        try await backfillDurations(for: page.items, req: req)

        return .init(
            items: page.items.map { SongResponse(song: $0) },
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

        var query = Song.query(on: req.db)
        if let format = req.query[String.self, at: "format"]?.trimmingCharacters(in: .whitespacesAndNewlines), !format.isEmpty {
            query = query.filter(\.$fileFormat == format.lowercased())
        }
        query = query
            .join(Artist.self, on: \Artist.$id == \Song.$artist.$id, method: .left)
            .filter(.sql(unsafeRaw: "LOWER(title) LIKE '%\(safeQuery.lowercased())%' OR LOWER(\"artists\".\"name\") LIKE '%\(safeQuery.lowercased())%'"))
        let songs = try await query.limit(50).all()

        for song in songs {
            try await song.$artist.load(on: req.db)
            try await song.$album.load(on: req.db)
        }
        try await backfillDurations(for: songs, req: req)
        return songs.map { SongResponse(song: $0) }
    }

    /// Lazily repairs historical rows scanned before native decoder metadata
    /// was used. Work is bounded to four files at a time and persisted, so
    /// subsequent list requests do not repeat decoder initialization.
    private func backfillDurations(for songs: [Song], req: Request) async throws {
        let missing = songs.compactMap { song -> (Song, String)? in
            guard song.duration == nil,
                  AudioFormat(rawValue: song.fileFormat) != nil else { return nil }
            let path = req.application.casStorage.resolve(sha256: song.sha256, format: song.fileFormat)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return (song, path)
        }

        for batchStart in stride(from: 0, to: missing.count, by: 4) {
            let batch = missing[batchStart..<min(batchStart + 4, missing.count)]
            let resolved = await withTaskGroup(of: (Song, Double?).self) { group in
                for (song, path) in batch {
                    group.addTask {
                        let duration: Double?
                        if CDecoderBridge.canDecode(format: song.fileFormat) {
                            duration = try? CDecoderBridge.duration(filePath: path, format: song.fileFormat)
                        } else {
                            let output = try? await ProcessRunner.execute(arguments: [
                                "ffprobe", "-v", "quiet", "-show_entries", "format=duration",
                                "-of", "default=noprint_wrappers=1:nokey=1", path,
                            ])
                            duration = output.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                        }
                        return (song, duration)
                    }
                }
                var values: [(Song, Double?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (song, duration) in resolved {
                guard let duration else { continue }
                song.duration = duration
                try await song.update(on: req.db)
            }
        }
    }

    /// GET /api/songs/:id — 歌曲详情
    @Sendable
    func show(req: Request) async throws -> SongResponse {
        guard let song = try await Song.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }
        try await song.$artist.load(on: req.db)
        try await song.$album.load(on: req.db)

        return SongResponse(song: song)
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
            let res = try await req.fileio.asyncStreamFile(at: path)
            res.headers.replaceOrAdd(name: .contentType, value: mime)
            return res

        case .wasmDecode(let path, _):
            return try await req.fileio.asyncStreamFile(at: path)

        case .serverDecode(let path, let fmt):
            // 尝试从转码缓存读取（避免重复 ffmpeg）
            let cachePath = try await cachedDecode(originalPath: path, sha256: song.sha256, format: fmt, subsong: subsong, cas: req.application.casStorage)
            let res = try await req.fileio.asyncStreamFile(at: cachePath)
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
        // Version output semantics so SDK/decoder upgrades never reuse stale PCM.
        let cachePath = "\(cacheDir)\(sha256)-\(AudioDecoder.cacheFingerprint)-\(format.rawValue)-rate-native-ch-native-sub-\(subsong).wav"

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
}
