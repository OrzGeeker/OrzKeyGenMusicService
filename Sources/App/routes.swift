import Fluent
import Vapor

func routes(_ app: Application) throws {
    // 前端页面
    try app.register(collection: FrontendController())

    // API
    try app.register(collection: SongController())
    try app.register(collection: ArtistController())
    try app.register(collection: AlbumController())
    try app.register(collection: PlaylistController())
    try app.register(collection: ScannerController())
    try app.register(collection: UploadController())
    try app.register(collection: SystemController())
}
