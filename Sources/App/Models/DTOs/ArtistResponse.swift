import Vapor

struct ArtistResponse: Content {
    let id: UUID
    let name: String
    let description: String?
    let songCount: Int?

    init(artist: Artist) {
        self.id = artist.id ?? UUID()
        self.name = artist.name
        self.description = artist.description
        self.songCount = nil
    }
}
