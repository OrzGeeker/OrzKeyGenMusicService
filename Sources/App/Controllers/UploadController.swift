import Vapor
import OrzAudioKit

struct UploadController: RouteCollection {
    private let adminAPIToken: String?

    init(adminAPIToken: String?) {
        self.adminAPIToken = adminAPIToken
    }

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api").grouped(AdminAPITokenMiddleware(token: adminAPIToken))
        api.post("upload", use: upload)
        api.delete("songs", ":id", use: delete)
    }

    /// POST /api/upload — 上传新音乐文件
    @Sendable
    func upload(req: Request) async throws -> HTTPStatus {
        struct UploadBody: Content {
            var file: File
            var artist: String?
            var title: String?
        }

        let body = try req.content.decode(UploadBody.self)

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
            relativePath: body.file.filename,
            artist: body.artist,
            title: body.title
        ) {
        case .created:
            return .created
        case .duplicate(let existing):
            throw Abort(.conflict, reason: "Duplicate file: \(existing.title)")
        }
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
