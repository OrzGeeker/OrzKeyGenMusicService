import Fluent

struct CreatePlaylist: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("playlists")
            .id()
            .field("name", .string, .required)
            .field("description", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("playlists").delete()
    }
}
