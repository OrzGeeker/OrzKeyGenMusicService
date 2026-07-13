import Fluent

struct CreateAlbum: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("albums")
            .id()
            .field("artist_id", .uuid, .required, .references("artists", "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("year", .int)
            .field("artwork_url", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "artist_id", "title")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("albums").delete()
    }
}
