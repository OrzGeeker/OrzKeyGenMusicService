import Fluent
import Vapor

final class Playlist: Model, Content, @unchecked Sendable {
    static let schema = "playlists"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @OptionalField(key: "description")
    var description: String?

    @Siblings(through: PlaylistSongPivot.self, from: \.$playlist, to: \.$song)
    var songs: [Song]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}
