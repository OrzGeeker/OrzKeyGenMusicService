import Fluent
import Vapor

final class Artist: Model, Content, @unchecked Sendable {
    static let schema = "artists"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @OptionalField(key: "description")
    var description: String?

    @Children(for: \.$artist)
    var albums: [Album]

    @Children(for: \.$artist)
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
