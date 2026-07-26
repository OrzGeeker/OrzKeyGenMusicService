import Fluent
import FluentSQL

struct CreateSongListIndexes: AsyncMigration {
    static let createdIndex = "idx_songs_created_at_id_desc"
    static let formatIndex = "idx_songs_format_created_at_id_desc"

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.sqlDatabaseRequired
        }
        try await sql.create(index: Self.createdIndex)
            .on("songs")
            .column(SQLOrderBy(expression: SQLIdentifier("created_at"), direction: SQLDirection.descending))
            .column(SQLOrderBy(expression: SQLIdentifier("id"), direction: SQLDirection.descending))
            .run()
        try await sql.create(index: Self.formatIndex)
            .on("songs")
            .column("file_format")
            .column(SQLOrderBy(expression: SQLIdentifier("created_at"), direction: SQLDirection.descending))
            .column(SQLOrderBy(expression: SQLIdentifier("id"), direction: SQLDirection.descending))
            .run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.sqlDatabaseRequired
        }
        try await sql.drop(index: Self.formatIndex).run()
        try await sql.drop(index: Self.createdIndex).run()
    }

    private enum MigrationError: Error {
        case sqlDatabaseRequired
    }
}
