import Vapor

enum ScanAPIError: AbortError {
    case alreadyRunning
    case rootNotConfigured
    case rootUnavailable(String)

    var status: HTTPResponseStatus {
        switch self {
        case .alreadyRunning:
            return .conflict
        case .rootNotConfigured, .rootUnavailable:
            return .serviceUnavailable
        }
    }

    var reason: String {
        switch self {
        case .alreadyRunning:
            return "A music library scan is already running"
        case .rootNotConfigured:
            return "SCAN_ROOT is not configured"
        case .rootUnavailable(let reason):
            return reason
        }
    }

    var errorCode: String {
        switch self {
        case .alreadyRunning:
            return "scan_already_running"
        case .rootNotConfigured:
            return "scan_root_not_configured"
        case .rootUnavailable:
            return "scan_root_unavailable"
        }
    }
}

actor ScanExecutionCoordinator {
    static let shared = ScanExecutionCoordinator()

    private var isRunning = false

    func tryBegin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    func finish() {
        isRunning = false
    }
}

struct ScannerController: RouteCollection {
    private let adminAPIToken: String?
    private let scanRoot: String?
    private let coordinator: ScanExecutionCoordinator

    init(
        adminAPIToken: String?,
        scanRoot: String?,
        coordinator: ScanExecutionCoordinator = .shared
    ) {
        self.adminAPIToken = adminAPIToken
        self.scanRoot = scanRoot
        self.coordinator = coordinator
    }

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api").grouped(AdminAPITokenMiddleware(token: adminAPIToken))
        api.post("scan", use: scan)
    }

    /// POST /api/scan — 扫描服务端配置的 SCAN_ROOT，导入 CAS
    @Sendable
    func scan(req: Request) async throws -> MusicScannerService.ScanResult {
        guard let scanRoot else {
            throw ScanAPIError.rootNotConfigured
        }
        guard await coordinator.tryBegin() else {
            throw ScanAPIError.alreadyRunning
        }

        let service = MusicScannerService(
            sourceRoot: scanRoot,
            cas: req.application.casStorage,
            db: req.db
        )

        do {
            let result = try await service.scan()
            await coordinator.finish()
            return result
        } catch {
            await coordinator.finish()
            throw error
        }
    }
}
