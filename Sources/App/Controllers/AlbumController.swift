import Vapor
import Fluent

struct AlbumController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let albums = routes.grouped("api", "albums")
        albums.get(use: index)
        albums.group(":id") { album in
            album.get(use: show)
        }
    }

    /// GET /api/albums
    @Sendable
    func index(req: Request) async throws -> Page<AlbumResponse> {
        let page = try await Album.query(on: req.db)
            .with(\.$artist)
            .sort(\.$title, .ascending)
            .paginate(for: req)
        return .init(
            items: page.items.map { AlbumResponse(album: $0) },
            metadata: page.metadata
        )
    }

    /// GET /api/albums/:id
    @Sendable
    func show(req: Request) async throws -> AlbumResponse {
        guard let album = try await Album.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }
        return AlbumResponse(album: album)
    }
}
