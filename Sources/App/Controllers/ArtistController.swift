import Vapor
import Fluent

struct ArtistController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let artists = routes.grouped("api", "artists")
        artists.get(use: index)
        artists.group(":id") { artist in
            artist.get(use: show)
            artist.get("songs", use: songs)
        }
    }

    /// GET /api/artists
    @Sendable
    func index(req: Request) async throws -> Page<ArtistResponse> {
        let page = try await Artist.query(on: req.db)
            .sort(\.$name, .ascending)
            .paginate(for: req)

        var responses: [ArtistResponse] = []
        for artist in page.items {
            let count = try await Song.query(on: req.db)
                .filter("artist_id", .equal, artist.id!)
                .count()
            responses.append(ArtistResponse(artist: artist, songCount: count))
        }
        return .init(
            items: responses,
            metadata: page.metadata
        )
    }

    /// GET /api/artists/:id
    @Sendable
    func show(req: Request) async throws -> ArtistResponse {
        guard let artist = try await Artist.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }
        let songCount = try await Song.query(on: req.db)
            .filter("artist_id", .equal, artist.id!)
            .count()
        return ArtistResponse(artist: artist, songCount: songCount)
    }

    /// GET /api/artists/:id/songs
    @Sendable
    func songs(req: Request) async throws -> Page<SongResponse> {
        guard let artist = try await Artist.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }

        let page = try await Song.query(on: req.db)
            .filter("artist_id", .equal, artist.id!)
            .with(\.$artist)
            .with(\.$album)
            .sort(\.$title, .ascending)
            .paginate(for: req)

        let baseURL = "\(req.headers.first(name: "x-forwarded-proto") ?? "http")://\(req.headers.first(name: "host") ?? "localhost:8080")"
        return .init(
            items: page.items.map { SongResponse(song: $0, baseURL: baseURL) },
            metadata: page.metadata
        )
    }
}
