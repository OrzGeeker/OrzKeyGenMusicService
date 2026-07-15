import Fluent

/// Schema migration: 去掉 file_path，sha256 设为唯一
///
/// 适用于从旧 schema 升级的数据库。新部署使用更新后的 CreateSong 自带头。
struct MigrateSongToCas: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("songs")
            .deleteField("file_path")
            .unique(on: "sha256")
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("songs")
            .deleteUnique(on: "sha256")
            .field("file_path", .string, .required)
            .update()
    }
}
