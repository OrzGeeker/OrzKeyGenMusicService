import Fluent

struct CreateSong: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("songs")
            .id()
            .field("artist_id", .uuid, .references("artists", "id", onDelete: .setNull))
            .field("album_id", .uuid, .references("albums", "id", onDelete: .setNull))
            .field("title", .string, .required)
            .field("track_number", .int)
            .field("file_path", .string, .required)
            .field("file_format", .string, .required)
            .field("file_size", .int, .required)
            .field("duration", .double)
            .field("audio_fingerprint", .string)
            .field("sha256", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("songs").delete()
    }
}
