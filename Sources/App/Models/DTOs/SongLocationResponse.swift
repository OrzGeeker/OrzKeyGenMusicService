import Vapor

/// GET /api/songs/:id/location 响应
/// index 为全曲库默认排序（createdAt DESC, id DESC）中的零基位置
/// page 为一基页码
struct SongLocationResponse: Content {
    let songId: UUID
    let index: Int
    let page: Int
    let per: Int
}
