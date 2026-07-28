import Vapor

struct SystemController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")
        api.get("health", use: health)
        api.get("stats", use: stats)
        api.get("openapi.json", use: openAPI)
    }

    /// GET /api/health — 健康与版本检查
    ///
    /// 所有依赖可用时返回 HTTP 200 + `status: "ready"`；
    /// 任一依赖不可用时返回 HTTP 503 + `status: "degraded"`。
    /// 响应不暴露路径、凭证或内部错误堆栈。
    @Sendable
    func health(req: Request) async throws -> Response {
        let version = AppVersion.current
        let commit = ProcessInfo.processInfo.environment["GIT_COMMIT"] ?? "unknown"

        // 数据库健康：轻量查询
        let dbHealthy: Bool
        do {
            _ = try await Song.query(on: req.db).limit(1).all()
            dbHealthy = true
        } catch {
            dbHealthy = false
        }

        // CAS 健康：只检查根目录可读性，不做写入
        let casRoot = req.application.casStorage.root
        let casHealthy = FileManager.default.isReadableFile(atPath: casRoot)

        let allHealthy = dbHealthy && casHealthy
        let healthResponse = HealthResponse(
            status: allHealthy ? "ready" : "degraded",
            version: version,
            commit: commit,
            database: dbHealthy ? "healthy" : "unhealthy",
            cas: casHealthy ? "healthy" : "unhealthy"
        )

        let response = Response(status: allHealthy ? .ok : .serviceUnavailable)
        try response.content.encode(healthResponse)
        return response
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
                "version": AppVersion.current,
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
                        "security": [["AdminBearer": []]],
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string", "format": "uuid"]]
                        ],
                        "responses": [
                            "204": ["description": "Deleted successfully"],
                            "401": ["description": "Missing or invalid admin token"],
                            "404": ["description": "Song not found"],
                            "503": ["description": "Admin API is disabled"]
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
                        "summary": "Scan configured music library",
                        "description": "Scans the server-configured SCAN_ROOT only, imports files into CAS (content-addressed storage), and creates Song records. This operation does not accept source paths from clients.",
                        "security": [["AdminBearer": []]],
                        "responses": [
                            "200": ["description": "Scan result with counts"],
                            "401": ["description": "Missing or invalid admin token"],
                            "409": ["description": "A scan is already running"],
                            "503": ["description": "Admin API is disabled or SCAN_ROOT is unavailable"]
                        ]
                    ]
                ],
                "/api/upload": [
                    "post": [
                        "summary": "Upload music file",
                        "description": "Upload a single audio file up to 32 MiB. Automatically deduplicates via SHA-256. relativePath is used for metadata inference when artist and title are not provided.",
                        "security": [["AdminBearer": []]],
                        "requestBody": [
                            "content": [
                                "multipart/form-data": [
                                    "schema": [
                                        "type": "object",
                                        "properties": [
                                            "file": ["type": "string", "format": "binary"],
                                            "relativePath": ["type": "string"],
                                            "artist": ["type": "string"],
                                            "title": ["type": "string"]
                                        ] as [String: Any],
                                        "required": ["file"]
                                    ] as [String: Any]
                                ]
                            ]
                        ],
                        "responses": [
                            "201": ["description": "Uploaded successfully; returns { status: created, song }"],
                            "200": ["description": "Duplicate upload; returns { status: duplicate, song }"],
                            "400": ["description": "Missing file or unsupported format"],
                            "413": ["description": "File exceeds 32 MiB; error is upload_too_large"],
                            "401": ["description": "Missing or invalid admin token"],
                            "503": ["description": "Admin API is disabled"]
                        ]
                    ] as [String: Any]
                ]
            ] as [String: Any],
            "components": [
                "securitySchemes": [
                    "AdminBearer": [
                        "type": "http",
                        "scheme": "bearer",
                        "bearerFormat": "Bearer token",
                        "description": "Set to the ADMIN_API_TOKEN configured on the server. Required for administrative write operations."
                    ] as [String: Any]
                ],
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

struct HealthResponse: Content {
    let status: String
    let version: String
    let commit: String
    let database: String
    let cas: String
}
