import Vapor

struct SystemController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")
        api.get("stats", use: stats)
        api.get("openapi.json", use: openAPI)
    }

    /// GET /api/stats — 库统计
    @Sendable
    func stats(req: Request) async throws -> StatsResponse {
        async let songCount = Song.query(on: req.db).count()
        async let artistCount = Artist.query(on: req.db).count()
        async let albumCount = Album.query(on: req.db).count()
        async let playlistCount = Playlist.query(on: req.db).count()

        // 加载所有歌曲汇总文件大小（Fluent 的 sum() 聚合在 PostgresNIO
        // 中存在类型解码问题，改用 Swift 层面手动汇总）
        let totalSize = try await Song.query(on: req.db).all().reduce(0) { $0 + $1.fileSize }

        return StatsResponse(
            totalSongs: try await songCount,
            totalArtists: try await artistCount,
            totalAlbums: try await albumCount,
            totalPlaylists: try await playlistCount,
            totalFileSize: totalSize
        )
    }

    /// GET /api/openapi.json — OpenAPI 3.0 规范
    @Sendable
    func openAPI(req: Request) async throws -> Response {
        let baseURL = "\(req.headers.first(name: "x-forwarded-proto") ?? "http")://\(req.headers.first(name: "host") ?? "localhost:8080")"

        let spec: [String: Any] = [
            "openapi": "3.0.3",
            "info": [
                "title": "OrzPlayer Music API",
                "version": "1.1.0",
                "description": "Music management and streaming API for OrzPlayer\n\nSupports 25+ audio formats with automatic playback strategy selection (directFile / wasmDecode / serverDecode)."
            ] as [String: Any],
            "servers": [
                ["url": baseURL, "description": "Current server"]
            ],
            "paths": [
                "/api/songs": [
                    "get": [
                        "summary": "List songs",
                        "description": "Paginated list of all songs, sorted by creation date descending",
                        "parameters": [
                            ["name": "page", "in": "query", "schema": ["type": "integer", "default": 1]],
                            ["name": "per", "in": "query", "schema": ["type": "integer", "default": 50]],
                            ["name": "format", "in": "query", "schema": ["type": "string"], "description": "Filter by file format (xm, mod, mp3, etc.)"]
                        ],
                        "responses": [
                            "200": ["description": "Paginated song list"]
                        ]
                    ] as [String: Any]
                ],
                "/api/songs/search": [
                    "get": [
                        "summary": "Search songs",
                        "description": "Search songs by title or artist name (case-insensitive ILIKE)",
                        "parameters": [
                            ["name": "q", "in": "query", "required": true, "schema": ["type": "string"]]
                        ],
                        "responses": [
                            "200": ["description": "Matching songs"]
                        ]
                    ] as [String: Any]
                ],
                "/api/songs/{id}": [
                    "get": [
                        "summary": "Get song details",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "responses": [
                            "200": ["description": "Song details with playStrategy"],
                            "404": ["description": "Song not found"]
                        ]
                    ] as [String: Any],
                    "delete": [
                        "summary": "Delete a song",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "responses": [
                            "204": ["description": "Deleted successfully"],
                            "404": ["description": "Song not found"]
                        ]
                    ] as [String: Any]
                ],
                "/api/songs/{id}/stream": [
                    "get": [
                        "summary": "Stream audio file",
                        "description": "Streams the original file for browser-native formats, or transcodes to WAV via ffmpeg for server-decode formats",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "responses": [
                            "200": ["description": "Audio stream (original file or WAV)"],
                            "404": ["description": "Song or file not found"]
                        ]
                    ] as [String: Any]
                ],
                "/api/songs/{id}/raw": [
                    "get": [
                        "summary": "Download raw file",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "responses": [
                            "200": ["description": "Raw audio file download"]
                        ]
                    ] as [String: Any]
                ],
                "/api/artists": [
                    "get": [
                        "summary": "List artists",
                        "description": "Paginated list with song counts per artist",
                        "parameters": [
                            ["name": "page", "in": "query", "schema": ["type": "integer", "default": 1]],
                            ["name": "per", "in": "query", "schema": ["type": "integer", "default": 50]]
                        ],
                        "responses": [
                            "200": ["description": "Paginated artist list with songCount"]
                        ]
                    ] as [String: Any]
                ],
                "/api/artists/{id}": [
                    "get": [
                        "summary": "Get artist details",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "responses": [
                            "200": ["description": "Artist details with songCount"]
                        ]
                    ] as [String: Any]
                ],
                "/api/artists/{id}/songs": [
                    "get": [
                        "summary": "Get artist's songs",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]],
                            ["name": "page", "in": "query", "schema": ["type": "integer", "default": 1]],
                            ["name": "per", "in": "query", "schema": ["type": "integer", "default": 50]]
                        ],
                        "responses": [
                            "200": ["description": "Paginated song list for the artist"]
                        ]
                    ] as [String: Any]
                ],
                "/api/albums": [
                    "get": [
                        "summary": "List albums",
                        "description": "Paginated list with artist info",
                        "parameters": [
                            ["name": "page", "in": "query", "schema": ["type": "integer", "default": 1]],
                            ["name": "per", "in": "query", "schema": ["type": "integer", "default": 50]]
                        ],
                        "responses": [
                            "200": ["description": "Paginated album list"]
                        ]
                    ] as [String: Any]
                ],
                "/api/albums/{id}": [
                    "get": [
                        "summary": "Get album details",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "responses": [
                            "200": ["description": "Album details"],
                            "404": ["description": "Album not found"]
                        ]
                    ] as [String: Any]
                ],
                "/api/playlists": [
                    "get": [
                        "summary": "List playlists",
                        "responses": [
                            "200": ["description": "List of all playlists"]
                        ]
                    ] as [String: Any],
                    "post": [
                        "summary": "Create playlist",
                        "requestBody": [
                            "content": [
                                "application/json": [
                                    "schema": [
                                        "type": "object",
                                        "properties": [
                                            "name": ["type": "string"],
                                            "description": ["type": "string"]
                                        ] as [String: Any],
                                        "required": ["name"]
                                    ] as [String: Any]
                                ]
                            ]
                        ],
                        "responses": [
                            "201": ["description": "Created playlist"]
                        ]
                    ] as [String: Any]
                ],
                "/api/playlists/{id}": [
                    "get": [
                        "summary": "Get playlist with songs",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "responses": [
                            "200": ["description": "Playlist details with songs"]
                        ]
                    ] as [String: Any],
                    "put": [
                        "summary": "Update playlist",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "responses": [
                            "200": ["description": "Updated playlist"]
                        ]
                    ] as [String: Any],
                    "delete": [
                        "summary": "Delete playlist",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "responses": [
                            "204": ["description": "Deleted"]
                        ]
                    ] as [String: Any]
                ],
                "/api/playlists/{id}/songs": [
                    "post": [
                        "summary": "Add song to playlist",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "requestBody": [
                            "content": [
                                "application/json": [
                                    "schema": [
                                        "type": "object",
                                        "properties": ["songId": ["type": "string", "format": "uuid"]] as [String: Any],
                                        "required": ["songId"]
                                    ] as [String: Any]
                                ]
                            ]
                        ],
                        "responses": [
                            "201": ["description": "Added"]
                        ]
                    ] as [String: Any]
                ],
                "/api/playlists/{id}/songs/{songId}": [
                    "delete": [
                        "summary": "Remove song from playlist",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]],
                            ["name": "songId", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "responses": [
                            "204": ["description": "Removed"]
                        ]
                    ] as [String: Any]
                ],
                "/api/playlists/{id}/songs/reorder": [
                    "put": [
                        "summary": "Reorder songs in playlist",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "responses": [
                            "200": ["description": "Reordered"]
                        ]
                    ] as [String: Any]
                ],
                "/api/stats": [
                    "get": [
                        "summary": "Library statistics",
                        "responses": [
                            "200": ["description": "Statistics (totalSongs, totalArtists, etc.)"]
                        ]
                    ]
                ],
                "/api/scan": [
                    "post": [
                        "summary": "Scan music library",
                        "description": "Scans MUSIC_PATH (or Public directory) for new and removed audio files, upserts database records",
                        "responses": [
                            "200": ["description": "Scan result with counts"]
                        ]
                    ]
                ],
                "/api/upload": [
                    "post": [
                        "summary": "Upload music file",
                        "description": "Upload a single audio file. Automatically deduplicates via SHA-256.",
                        "requestBody": [
                            "content": [
                                "multipart/form-data": [
                                    "schema": [
                                        "type": "object",
                                        "properties": [
                                            "file": ["type": "string", "format": "binary"],
                                            "artist": ["type": "string"],
                                            "title": ["type": "string"]
                                        ] as [String: Any],
                                        "required": ["file"]
                                    ] as [String: Any]
                                ]
                            ]
                        ],
                        "responses": [
                            "201": ["description": "Uploaded successfully"],
                            "409": ["description": "Duplicate file"]
                        ]
                    ] as [String: Any]
                ]
            ] as [String: Any],
            "components": [
                "schemas": [
                    "SongResponse": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string", "format": "uuid"],
                            "title": ["type": "string"],
                            "filePath": ["type": "string"],
                            "fileFormat": ["type": "string"],
                            "fileSize": ["type": "integer"],
                            "duration": ["type": "number", "nullable": true],
                            "artist": ["type": "object", "nullable": true],
                            "album": ["type": "object", "nullable": true],
                            "streamUrl": ["type": "string"],
                            "rawUrl": ["type": "string"],
                            "playStrategy": ["type": "string", "enum": ["directFile", "wasmDecode", "serverDecode"]],
                            "createdAt": ["type": "string", "format": "date-time"],
                            "updatedAt": ["type": "string", "format": "date-time"]
                        ] as [String: Any]
                    ] as [String: Any],
                    "StatsResponse": [
                        "type": "object",
                        "properties": [
                            "totalSongs": ["type": "integer"],
                            "totalArtists": ["type": "integer"],
                            "totalAlbums": ["type": "integer"],
                            "totalPlaylists": ["type": "integer"],
                            "totalFileSize": ["type": "integer"]
                        ] as [String: Any]
                    ] as [String: Any]
                ]
            ] as [String: Any]
        ]

        let json = try JSONSerialization.data(withJSONObject: spec, options: [.prettyPrinted])
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return Response(status: .ok, headers: headers, body: .init(data: json))
    }
}

struct StatsResponse: Content {
    let totalSongs: Int
    let totalArtists: Int
    let totalAlbums: Int
    let totalPlaylists: Int
    let totalFileSize: Int?
}
