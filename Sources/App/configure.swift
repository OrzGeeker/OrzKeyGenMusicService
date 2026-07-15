import Fluent
import FluentPostgresDriver
import Leaf
import Vapor

// configures your application
public func configure(_ app: Application) throws {

    // CORS — 允许前端跨域访问
    let corsConfig = CORSMiddleware.Configuration(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .PUT, .DELETE, .OPTIONS, .PATCH],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
    )
    app.middleware.use(CORSMiddleware(configuration: corsConfig))

    // 统一错误响应格式
    app.middleware.use(ErrorResponseMiddleware())

    // 静态文件 — Public 目录（用于前端 JS/CSS，不再用于音乐文件）
    app.directory.publicDirectory = "\(app.directory.resourcesDirectory)Public/"
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // CAS（Content-Addressed Storage）初始化
    let casRoot = Environment.get("CAS_ROOT") ?? "./data/music"
    app.casStorage = CasStorageService(root: casRoot)

    app.databases.use(
        .postgres(
            configuration: .init(
                hostname: Environment.get("DATABASE_HOST") ?? "localhost",
                port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
                username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
                password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
                database: Environment.get("DATABASE_NAME") ?? "vapor_database",
                tls: .disable)
        ),
        as: .psql
    )

    // Migrations
    app.migrations.add(CreateArtist())
    app.migrations.add(CreateAlbum())
    app.migrations.add(CreateSong())
    app.migrations.add(CreatePlaylist())
    app.migrations.add(CreatePlaylistSongPivot())
    // 注意：MigrateSongToCas 仅用于从旧 schema 升级，新 DB 由 CreateSong 直接创建正确 schema

    app.views.use(.leaf)

    // register routes
    try routes(app)
}
