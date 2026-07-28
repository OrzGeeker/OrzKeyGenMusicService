import Vapor
import OrzAudioKit

struct UploadController: RouteCollection {
    /// The maximum bytes in the uploaded audio file. The route accepts an
    /// additional 64 KiB for multipart boundaries and the optional text fields.
    static let maximumUploadFileSize = 32 * 1024 * 1024
    private static let maximumUploadRequestSize = maximumUploadFileSize + 64 * 1024

    struct UploadResponse: Content {
        let status: String
        let song: SongResponse
    }

    private let adminAPIToken: String?

    init(adminAPIToken: String?) {
        self.adminAPIToken = adminAPIToken
    }

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api").grouped(AdminAPITokenMiddleware(token: adminAPIToken))
        // Keep the file limit exact while allowing the multipart envelope. The
        // decoded file is checked below before any CAS or database mutation.
        api.on(
            .POST,
            "upload",
            body: .collect(maxSize: ByteCount(value: Self.maximumUploadRequestSize)),
            use: upload
        )
        api.delete("songs", ":id", use: delete)
    }

    /// POST /api/upload — 上传新音乐文件
    @Sendable
    func upload(req: Request) async throws -> Response {
        struct UploadBody: Content {
            var file: File
            var relativePath: String?
            var artist: String?
            var title: String?
        }

        let body = try req.content.decode(UploadBody.self)

        guard body.file.data.readableBytes <= Self.maximumUploadFileSize else {
            throw Abort(
                .payloadTooLarge,
                reason: "Uploaded file exceeds the 32 MiB limit"
            )
        }

        // 检测格式
        let ext = (body.file.filename as NSString).pathExtension.lowercased()
        guard AudioFormat.from(fileExtension: ext) != nil else {
            throw Abort(.badRequest, reason: "Unsupported file format: \(ext)")
        }

        // 写入临时文件
        guard let fileData = body.file.data.getData(at: 0, length: body.file.data.readableBytes) else {
            throw Abort(.badRequest, reason: "Cannot read uploaded file")
        }
        let tmpPath = "/tmp/orz_upload_\(UUID().uuidString).\(ext)"
        try fileData.write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let importer = MusicImportService(cas: req.application.casStorage, db: req.db)
        switch try await importer.importFile(
            sourcePath: tmpPath,
            relativePath: body.relativePath ?? body.file.filename,
            artist: body.artist,
            title: body.title
        ) {
        case .created(let song):
            return try await response(for: song, status: "created", httpStatus: .created, on: req)
        case .duplicate(let song):
            return try await response(for: song, status: "duplicate", httpStatus: .ok, on: req)
        }
    }

    private func response(
        for song: Song,
        status: String,
        httpStatus: HTTPStatus,
        on request: Request
    ) async throws -> Response {
        try await song.$artist.load(on: request.db)
        let response = Response(status: httpStatus)
        try response.content.encode(UploadResponse(status: status, song: SongResponse(song: song)))
        return response
    }

    /// DELETE /api/songs/:id — 删除歌曲及 CAS 文件
    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        guard let song = try await Song.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }

        // 删除 CAS 文件
        let cas = req.application.casStorage
        try cas.delete(sha256: song.sha256, format: song.fileFormat)

        try await song.delete(on: req.db)
        return .noContent
    }
}
