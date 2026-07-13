import Vapor

struct ArtistResponse: Content {
    let id: UUID
    let name: String
    let description: String?
    let songCount: Int

    init(artist: Artist, songCount: Int = 0) {
        self.id = artist.id ?? UUID()
        self.name = artist.name
        self.description = artist.description
        self.songCount = songCount
    }
}
