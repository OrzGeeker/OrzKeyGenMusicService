import Vapor

struct PlaylistResponse: Content {
    let id: UUID
    let name: String
    let description: String?
    let songCount: Int?
    let songs: [SongResponse]?

    init(playlist: Playlist, songCount: Int? = nil, songs: [SongResponse]? = nil) {
        self.id = playlist.id ?? UUID()
        self.name = playlist.name
        self.description = playlist.description
        self.songCount = songs?.count ?? songCount
        self.songs = songs
    }
}
