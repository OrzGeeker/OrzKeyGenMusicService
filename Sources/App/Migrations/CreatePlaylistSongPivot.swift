import Fluent

struct CreatePlaylistSongPivot: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("playlist_songs")
            .id()
            .field("playlist_id", .uuid, .required, .references("playlists", "id", onDelete: .cascade))
            .field("song_id", .uuid, .required, .references("songs", "id", onDelete: .cascade))
            .field("position", .int, .required)
            .field("created_at", .datetime)
            .unique(on: "playlist_id", "position")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("playlist_songs").delete()
    }
}
