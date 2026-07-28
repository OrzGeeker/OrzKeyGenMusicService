import Vapor

struct ScannerController: RouteCollection {
    private let adminAPIToken: String?

    init(adminAPIToken: String?) {
        self.adminAPIToken = adminAPIToken
    }

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api").grouped(AdminAPITokenMiddleware(token: adminAPIToken))
        api.post("scan", use: scan)
    }

    struct ScanRequestBody: Content {
        var sources: [String]
    }

    /// POST /api/scan — 扫描指定来源目录，导入 CAS
    ///
    /// Request body:
    ///   { "sources": ["/path/to/music", "/path/to/keygenmusic"] }
    @Sendable
    func scan(req: Request) async throws -> MusicScannerService.ScanResult {
        let body = try req.content.decode(ScanRequestBody.self)

        guard !body.sources.isEmpty else {
            throw Abort(.badRequest, reason: "sources must contain at least one directory path")
        }

        let service = MusicScannerService(
            sourcePaths: body.sources,
            cas: req.application.casStorage,
            db: req.db
        )
        return try await service.scan()
    }
}
