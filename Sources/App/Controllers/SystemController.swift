import Vapor

struct SystemController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")
        api.get("stats", use: stats)
        api.get("openapi.json", use: openAPI)
    }

    /// GET /api/stats — 库统计
    @Sendable
    func stats(req: Request) async throws -> StatsResponse {
        async let songCount = Song.query(on: req.db).count()
        async let artistCount = Artist.query(on: req.db).count()
        async let albumCount = Album.query(on: req.db).count()
        async let playlistCount = Playlist.query(on: req.db).count()

        let totalSize = try await Song.query(on: req.db).all().reduce(0) { $0 + $1.fileSize }

        return StatsResponse(
            totalSongs: try await songCount,
            totalArtists: try await artistCount,
            totalAlbums: try await albumCount,
            totalPlaylists: try await playlistCount,
            totalFileSize: totalSize
        )
    }

    /// GET /api/openapi.json — OpenAPI 3.0 规范
    @Sendable
    func openAPI(req: Request) async throws -> Response {
        // 简单内联 OpenAPI 规范
        let spec: [String: Any] = [
            "openapi": "3.0.3",
            "info": [
                "title": "OrzPlayer Music API",
                "version": "1.0.0",
                "description": "Music management and streaming API for OrzPlayer"
            ],
            "servers": [
                ["url": "/", "description": "Local server"]
            ],
            "paths": [
                "/api/songs": ["get": ["summary": "List songs"]],
                "/api/songs/{id}/stream": ["get": ["summary": "Stream audio file"]],
                "/api/songs/{id}/raw": ["get": ["summary": "Download raw file"]],
                "/api/artists": ["get": ["summary": "List artists"]],
                "/api/albums": ["get": ["summary": "List albums"]],
                "/api/playlists": ["get": ["summary": "List playlists"], "post": ["summary": "Create playlist"]],
                "/api/stats": ["get": ["summary": "Library statistics"]],
                "/api/scan": ["post": ["summary": "Scan music library"]],
                "/api/upload": ["post": ["summary": "Upload music file"]]
            ]
        ]

        let json = try JSONSerialization.data(withJSONObject: spec, options: [.prettyPrinted])
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return Response(status: .ok, headers: headers, body: .init(data: json))
    }
}

struct StatsResponse: Content {
    let totalSongs: Int
    let totalArtists: Int
    let totalAlbums: Int
    let totalPlaylists: Int
    let totalFileSize: Int
}
