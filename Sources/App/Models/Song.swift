import Fluent
import Vapor

final class Song: Model, Content, @unchecked Sendable {
    static let schema = "songs"

    @ID(key: .id)
    var id: UUID?

    @OptionalParent(key: "artist_id")
    var artist: Artist?

    @OptionalParent(key: "album_id")
    var album: Album?

    @Field(key: "title")
    var title: String

    @OptionalField(key: "track_number")
    var trackNumber: Int?

    @Field(key: "file_path")
    var filePath: String

    @Field(key: "file_format")
    var fileFormat: String

    @Field(key: "file_size")
    var fileSize: Int

    @OptionalField(key: "duration")
    var duration: Double?

    @OptionalField(key: "audio_fingerprint")
    var audioFingerprint: String?

    @OptionalField(key: "sha256")
    var sha256: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, title: String, filePath: String, fileFormat: String,
         fileSize: Int, duration: Double? = nil) {
        self.id = id
        self.title = title
        self.filePath = filePath
        self.fileFormat = fileFormat
        self.fileSize = fileSize
        self.duration = duration
    }
}
