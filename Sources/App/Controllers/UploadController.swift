import Vapor
import OrzAudioKit

struct UploadController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")
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
        let publicDir = req.application.directory.publicDirectory

        // 检测格式
        let ext = (body.file.filename as NSString).pathExtension.lowercased()
        guard let format = AudioFormat.from(fileExtension: ext) else {
            throw Abort(.badRequest, reason: "Unsupported file format: \(ext)")
        }

        // 读取文件内容
        guard let fileData = body.file.data.getData(at: 0, length: body.file.data.readableBytes) else {
            throw Abort(.badRequest, reason: "Cannot read uploaded file")
        }

        // 计算 SHA-256 去重
        let sha256 = try computeSHA256(data: fileData)

        // 检查是否已存在
        if let existing = try await Song.query(on: req.db).filter("sha256", .equal, sha256).first() {
            throw Abort(.conflict, reason: "Duplicate file: \(existing.title)")
        }

        // 写入 Public 目录
        let uploadDir = "\(publicDir)uploads/"
        try FileManager.default.createDirectory(atPath: uploadDir, withIntermediateDirectories: true)

        let fileName = "\(UUID().uuidString).\(ext)"
        let filePath = "uploads/\(fileName)"
        try fileData.write(to: URL(fileURLWithPath: "\(uploadDir)\(fileName)"))

        // 创建 Song 记录
        let title = body.title ?? (body.file.filename as NSString).deletingPathExtension
        let song = Song(title: title, filePath: filePath, fileFormat: ext, fileSize: fileData.count)
        song.sha256 = sha256

        // 关联 Artist
        if let artistName = body.artist {
            if let existingArtist = try await Artist.query(on: req.db).filter("name", .equal, artistName).first() {
                song.$artist.id = existingArtist.id
            } else {
                let newArtist = Artist(name: artistName)
                try await newArtist.create(on: req.db)
                song.$artist.id = newArtist.id
            }
        }

        try await song.create(on: req.db)
        return .created
    }

    /// DELETE /api/songs/:id — 删除歌曲
    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        guard let song = try await Song.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }

        // 删除文件
        let publicDir = req.application.directory.publicDirectory
        let fullPath = "\(publicDir)\(song.filePath)"
        try? FileManager.default.removeItem(atPath: fullPath)

        try await song.delete(on: req.db)
        return .noContent
    }

    private func computeSHA256(data: Data) throws -> String {
        let tmpPath = "/tmp/orz_upload_\(UUID().uuidString)"
        try data.write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["shasum", "-a", "256", tmpPath]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8),
              let hash = output.split(separator: " ").first
        else { throw Abort(.internalServerError, reason: "SHA-256 computation failed") }

        return String(hash)
    }
}
