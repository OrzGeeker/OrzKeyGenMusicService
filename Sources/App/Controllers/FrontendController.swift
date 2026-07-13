import Vapor

struct FrontendController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        routes.get(use: index)
    }

    /// GET / — 前端播放页面
    @Sendable
    func index(req: Request) async throws -> View {
        return try await req.view.render("player")
    }
}
