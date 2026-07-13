import Vapor

struct ScannerController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")
        api.post("scan", use: scan)
    }

    /// POST /api/scan — 触发全量扫描
    @Sendable
    func scan(req: Request) async throws -> MusicScannerService.ScanResult {
        // 优先使用 MUSIC_PATH 环境变量，否则默认扫描 Public 目录
        let musicPath = Environment.get("MUSIC_PATH")
            ?? req.application.directory.publicDirectory
        let service = MusicScannerService(basePath: musicPath, db: req.db)
        return try await service.scan()
    }
}
