import Vapor

struct AlbumResponse: Content {
    let id: UUID
    let title: String
    let year: Int?
    let artworkUrl: String?
    let artist: ArtistResponse?
    let songCount: Int?

    init(album: Album) {
        self.id = album.id ?? UUID()
        self.title = album.title
        self.year = album.year
        self.artworkUrl = album.artworkUrl
        self.artist = nil
        self.songCount = nil
    }
}
