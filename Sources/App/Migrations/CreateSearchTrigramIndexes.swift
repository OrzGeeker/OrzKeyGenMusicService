import Fluent
import FluentSQL

struct CreateSearchTrigramIndexes: AsyncMigration {
    static let titleIndex = "idx_songs_lower_title_trgm"
    static let artistNameIndex = "idx_artists_lower_name_trgm"
    static let songArtistIndex = "idx_songs_artist_id"

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.sqlDatabaseRequired
        }
        guard sql.dialect.name == "postgresql" else { return }

        try await sql.raw("CREATE EXTENSION IF NOT EXISTS pg_trgm").run()
        try await sql.raw(
            "CREATE INDEX \"idx_songs_lower_title_trgm\" " +
            "ON \"songs\" USING gin (lower(\"title\") gin_trgm_ops)"
        ).run()
        try await sql.raw(
            "CREATE INDEX \"idx_artists_lower_name_trgm\" " +
            "ON \"artists\" USING gin (lower(\"name\") gin_trgm_ops)"
        ).run()
        try await sql.create(index: Self.songArtistIndex)
            .on("songs")
            .column("artist_id")
            .run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.sqlDatabaseRequired
        }
        guard sql.dialect.name == "postgresql" else { return }

        try await sql.drop(index: Self.songArtistIndex).run()
        try await sql.drop(index: Self.artistNameIndex).run()
        try await sql.drop(index: Self.titleIndex).run()
        // pg_trgm may be shared by other objects, so the extension is intentionally retained.
    }

    private enum MigrationError: Error {
        case sqlDatabaseRequired
    }
}
