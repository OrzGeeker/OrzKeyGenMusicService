import Fluent

struct CreateArtist: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("artists")
            .id()
            .field("name", .string, .required)
            .field("description", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "name")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("artists").delete()
    }
}
