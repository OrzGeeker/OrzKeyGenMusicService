import Vapor
import OrzAudioKit

struct SongResponse: Content {
    let id: UUID
    let title: String
    let artist: ArtistResponse?
    let album: AlbumResponse?
    let fileFormat: String
    let fileSize: Int
    let duration: Double?
    let streamUrl: String
    let rawUrl: String
    let playStrategy: String

    init(song: Song) {
        self.id = song.id ?? UUID()
        self.title = song.title
        if let artist = song.artist {
            self.artist = ArtistResponse(artist: artist)
        } else {
            self.artist = nil
        }
        if let album = song.album {
            self.album = AlbumResponse(album: album)
        } else {
            self.album = nil
        }
        self.fileFormat = song.fileFormat
        self.fileSize = song.fileSize
        self.duration = song.duration
        let songId = song.id?.uuidString ?? ""
        self.streamUrl = "/api/songs/\(songId)/stream"
        self.rawUrl = "/api/songs/\(songId)/raw"
        self.playStrategy = AudioFormat(rawValue: song.fileFormat)?.playStrategy.rawValue ?? "serverDecode"
    }
}
