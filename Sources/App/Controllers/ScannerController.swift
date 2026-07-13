import Vapor

struct ScannerController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")
        api.post("scan", use: scan)
    }

    /// POST /api/scan — 触发全量扫描
    @Sendable
    func scan(req: Request) async throws -> MusicScannerService.ScanResult {
        let publicDir = req.application.directory.publicDirectory
        let service = MusicScannerService(basePath: publicDir, db: req.db)
        return try await service.scan()
    }
}
