import Vapor

struct FrontendController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        routes.get(use: index)
    }

    /// GET / — 前端播放页面
    @Sendable
    func index(req: Request) async throws -> View {
        struct Context: Encodable {
            let playbackDiagnosticsEnabled: Bool
        }
        return try await req.view.render("player", Context(
            playbackDiagnosticsEnabled: Environment.get("PLAYBACK_DIAGNOSTICS_ENABLED") == "true"
        ))
    }
}
