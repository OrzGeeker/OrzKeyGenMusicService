import Fluent
import Vapor

final class Album: Model, Content, @unchecked Sendable {
    static let schema = "albums"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "artist_id")
    var artist: Artist

    @Field(key: "title")
    var title: String

    @OptionalField(key: "year")
    var year: Int?

    @OptionalField(key: "artwork_url")
    var artworkUrl: String?

    @Children(for: \.$album)
    var songs: [Song]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, artistId: UUID, title: String, year: Int? = nil, artworkUrl: String? = nil) {
        self.id = id
        self.$artist.id = artistId
        self.title = title
        self.year = year
        self.artworkUrl = artworkUrl
    }
}
