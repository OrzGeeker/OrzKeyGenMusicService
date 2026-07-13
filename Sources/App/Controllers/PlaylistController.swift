import Vapor

struct PlaylistController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let playlists = routes.grouped("api", "playlists")
        playlists.get(use: index)
        playlists.post(use: create)
        playlists.group(":id") { pl in
            pl.get(use: show)
            pl.put(use: update)
            pl.delete(use: delete)
            pl.post("songs", use: addSong)
            pl.delete("songs", ":songId", use: removeSong)
            pl.put("songs", "reorder", use: reorderSongs)
        }
    }

    /// GET /api/playlists
    @Sendable
    func index(req: Request) async throws -> [PlaylistResponse] {
        let playlists = try await Playlist.query(on: req.db).all()
        return playlists.map { PlaylistResponse(playlist: $0) }
    }

    /// POST /api/playlists
    @Sendable
    func create(req: Request) async throws -> PlaylistResponse {
        struct CreateBody: Content {
            var name: String
            var description: String?
        }
        let body = try req.content.decode(CreateBody.self)
        let playlist = Playlist(name: body.name, description: body.description)
        try await playlist.create(on: req.db)
        return PlaylistResponse(playlist: playlist)
    }

    /// GET /api/playlists/:id
    @Sendable
    func show(req: Request) async throws -> PlaylistResponse {
        guard let playlist = try await Playlist.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }

        let songs = try await playlist.$songs.get(on: req.db)
        let baseURL = "\(req.headers.first(name: "x-forwarded-proto") ?? "http")://\(req.headers.first(name: "host") ?? "localhost:8080")"
        let songResponses = songs.map { SongResponse(song: $0, baseURL: baseURL) }

        return PlaylistResponse(playlist: playlist, songs: songResponses)
    }

    /// PUT /api/playlists/:id
    @Sendable
    func update(req: Request) async throws -> PlaylistResponse {
        struct UpdateBody: Content {
            var name: String?
            var description: String?
        }
        guard let playlist = try await Playlist.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }

        let body = try req.content.decode(UpdateBody.self)
        if let name = body.name { playlist.name = name }
        if let description = body.description { playlist.description = description }
        try await playlist.update(on: req.db)

        return PlaylistResponse(playlist: playlist)
    }

    /// DELETE /api/playlists/:id
    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        guard let playlist = try await Playlist.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }
        try await playlist.delete(on: req.db)
        return .noContent
    }

    /// POST /api/playlists/:id/songs
    @Sendable
    func addSong(req: Request) async throws -> HTTPStatus {
        struct AddBody: Content {
            var songId: UUID
        }
        guard let playlist = try await Playlist.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }

        let body = try req.content.decode(AddBody.self)
        guard let song = try await Song.find(body.songId, on: req.db) else {
            throw Abort(.notFound, reason: "Song not found")
        }

        // 获取当前最大 position
        let maxPos = try await PlaylistSongPivot.query(on: req.db)
            .filter("playlist_id", .equal, playlist.id!)
            .all()
            .map(\.position)
            .max() ?? 0

        let pivot = PlaylistSongPivot(playlistId: playlist.id!, songId: song.id!, position: maxPos + 1)
        try await pivot.create(on: req.db)

        return .created
    }

    /// DELETE /api/playlists/:id/songs/:songId
    @Sendable
    func removeSong(req: Request) async throws -> HTTPStatus {
        guard let playlist = try await Playlist.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }
        guard let songId = req.parameters.get("songId", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        try await PlaylistSongPivot.query(on: req.db)
            .filter("playlist_id", .equal, playlist.id!)
            .filter("song_id", .equal, songId)
            .delete()

        return .noContent
    }

    /// PUT /api/playlists/:id/songs/reorder
    @Sendable
    func reorderSongs(req: Request) async throws -> HTTPStatus {
        struct ReorderBody: Content {
            var songIds: [UUID]
        }
        guard let playlist = try await Playlist.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }

        let body = try req.content.decode(ReorderBody.self)

        // 删除旧顺序
        try await PlaylistSongPivot.query(on: req.db)
            .filter("playlist_id", .equal, playlist.id!)
            .delete()

        // 插入新顺序
        for (index, songId) in body.songIds.enumerated() {
            let pivot = PlaylistSongPivot(playlistId: playlist.id!, songId: songId, position: index)
            try await pivot.create(on: req.db)
        }

        return .ok
    }
}
