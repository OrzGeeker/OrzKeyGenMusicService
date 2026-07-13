import Fluent
import Vapor

final class PlaylistSongPivot: Model, Content, @unchecked Sendable {
    static let schema = "playlist_songs"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "playlist_id")
    var playlist: Playlist

    @Parent(key: "song_id")
    var song: Song

    @Field(key: "position")
    var position: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, playlistId: UUID, songId: UUID, position: Int) {
        self.id = id
        self.$playlist.id = playlistId
        self.$song.id = songId
        self.position = position
    }
}
