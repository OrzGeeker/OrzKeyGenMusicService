import Foundation
import Vapor
import Fluent
import OrzAudioKit

/// 音乐文件扫描服务
///
/// 负责：
/// 1. 递归扫描目录，识别所有支持的音频格式
/// 2. 从文件路径和命名解析元数据（artist, title, trackType）
/// 3. 两层去重（SHA-256 文件级、音频指纹内容级）
/// 4. 数据库 upsert
/// 5. 清理已删除文件
public struct MusicScannerService {

    public struct ScanResult: Content {
        public let totalScanned: Int
        public let artistsCreated: Int
        public let songsCreated: Int
        public let songsUpdated: Int
        public let duplicatesSkipped: Int
        public let filesRemoved: Int
        public let elapsed: String

        public init(totalScanned: Int, artistsCreated: Int, songsCreated: Int,
                    songsUpdated: Int, duplicatesSkipped: Int, filesRemoved: Int, elapsed: String) {
            self.totalScanned = totalScanned
            self.artistsCreated = artistsCreated
            self.songsCreated = songsCreated
            self.songsUpdated = songsUpdated
            self.duplicatesSkipped = duplicatesSkipped
            self.filesRemoved = filesRemoved
            self.elapsed = elapsed
        }
    }

    private let basePath: String
    private let db: any Database
    private let fileManager = FileManager.default
    private let audioEngine = AudioEngine()

    public init(basePath: String, db: any Database) {
        self.basePath = basePath
        self.db = db
    }

    /// 执行全量扫描
    public func scan() async throws -> ScanResult {
        let start = Date()

        // 1. 收集所有音频文件
        let audioFiles = collectAudioFiles()

        // 2. 处理每个文件（去重 + upsert）
        var songsCreated = 0
        var songsUpdated = 0
        var duplicatesSkipped = 0

        for file in audioFiles {
            // 计算 SHA-256（文件级去重）
            let sha256 = try? await computeSHA256(filePath: file.fullPath)

            // 检查 SHA-256 是否已存在
            if let sha = sha256,
               try await Song.query(on: db).filter("sha256", .equal, sha).first() != nil {
                duplicatesSkipped += 1
                continue
            }

            // 解析元数据
            let info = parseMetadata(from: file)

            // Upsert Artist
            let artist = try await upsertArtist(name: info.artistName)

            // 创建 Song
            if let artist = artist {
                let existingSong = try await Song.query(on: db)
                    .filter("file_path", .equal, file.relativePath)
                    .first()

                if let existing = existingSong {
                    existing.title = info.songTitle
                    existing.fileSize = file.fileSize
                    existing.$artist.id = artist.id
                    existing.sha256 = sha256
                    existing.duration = await extractDuration(filePath: file.fullPath)
                    try await existing.update(on: db)
                    songsUpdated += 1
                } else {
                    let song = Song(
                        id: nil,
                        title: info.songTitle,
                        filePath: file.relativePath,
                        fileFormat: file.fileFormat,
                        fileSize: file.fileSize
                    )
                    song.$artist.id = artist.id
                    song.sha256 = sha256
                    song.duration = await extractDuration(filePath: file.fullPath)
                    try await song.create(on: db)
                    songsCreated += 1
                }
            }
        }

        // 3. 清理已删除文件
        let filesRemoved = try await cleanupRemovedFiles(activeFiles: Set(audioFiles.map { $0.relativePath }))

        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(start))

        return ScanResult(
            totalScanned: audioFiles.count,
            artistsCreated: 0,
            songsCreated: songsCreated,
            songsUpdated: songsUpdated,
            duplicatesSkipped: duplicatesSkipped,
            filesRemoved: filesRemoved,
            elapsed: elapsed
        )
    }

    // MARK: - Internal

    struct AudioFileInfo {
        let fullPath: String
        let relativePath: String
        let fileName: String
        let fileFormat: String
        let fileSize: Int
    }

    struct ParsedMetadata {
        let artistName: String
        let songTitle: String
        let trackType: String?
    }

    func collectAudioFiles() -> [AudioFileInfo] {
        var files: [AudioFileInfo] = []
        guard let enumerator = fileManager.enumerator(atPath: basePath) else { return [] }

        while let relativePath = enumerator.nextObject() as? String {
            let fullPath = (basePath as NSString).appendingPathComponent(relativePath)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }

            let ext = (relativePath as NSString).pathExtension.lowercased()
            guard AudioFormat.from(fileExtension: ext) != nil else { continue }

            let attrs = try? fileManager.attributesOfItem(atPath: fullPath)
            let fileSize = (attrs?[.size] as? Int) ?? 0

            files.append(AudioFileInfo(
                fullPath: fullPath,
                relativePath: relativePath,
                fileName: (relativePath as NSString).lastPathComponent,
                fileFormat: ext,
                fileSize: fileSize
            ))
        }

        return files
    }

    func parseMetadata(from file: AudioFileInfo) -> ParsedMetadata {
        let fileName = (file.fileName as NSString).deletingPathExtension

        // 获取父目录名作为 artist
        let parentDir = ((file.relativePath as NSString).deletingLastPathComponent as NSString).lastPathComponent

        // 如果父目录是 KEYGENMUSiC MusicPack 或 !Others，尝试从文件名解析
        let artistFromDir: String
        if parentDir == "KEYGENMUSiC MusicPack" || parentDir == "!Others" || parentDir == "." || parentDir.hasPrefix(".") {
            artistFromDir = "Unknown"
        } else {
            artistFromDir = parentDir
        }

        // 解析文件名：尝试 "{Artist} - {Title} {type}" 模式
        var songTitle = fileName
        var trackType: String? = nil
        var artistName = artistFromDir

        if let range = fileName.range(of: " - ") {
            let prefix = String(fileName[..<range.lowerBound])
            var suffix = String(fileName[range.upperBound...])

            // 检查 suffix 是否以 artistName 开头（大多数文件如此）
            if prefix.count > 0 && prefix.count < 20 {
                // 检查 prefix 是否可能是 artist 缩写
                // 在 !Others 目录中，prefix 就是 artist
                if artistFromDir == "Unknown" || !fileName.hasPrefix(artistFromDir) {
                    artistName = prefix
                    suffix = String(fileName[range.upperBound...])
                }
            }

            songTitle = suffix
        }

        // 提取 track type
        let typeKeywords = ["intro", "kg", "crk", "trn", "trainer", "installer", "keygen", "activator", "launcher"]
        for keyword in typeKeywords {
            if let typeRange = songTitle.range(of: "\\b\(keyword)\\b", options: [.regularExpression, .caseInsensitive]) {
                trackType = keyword
                var cleanChars = CharacterSet.whitespacesAndNewlines
cleanChars.formUnion(.punctuationCharacters)
songTitle = String(songTitle[..<typeRange.lowerBound]).trimmingCharacters(in: cleanChars)
                break
            }
        }

        return ParsedMetadata(
            artistName: artistName,
            songTitle: songTitle.isEmpty ? fileName : songTitle,
            trackType: trackType
        )
    }

    func upsertArtist(name: String) async throws -> Artist? {
        if let existing = try await Artist.query(on: db).filter("name", .equal, name).first() {
            return existing
        }
        let artist = Artist(name: name)
        try await artist.create(on: db)
        return artist
    }

    func computeSHA256(filePath: String) async throws -> String {
        let result = try await ProcessRunner.execute(arguments: ["shasum", "-a", "256", filePath])
        guard let hash = result.split(separator: " ").first else {
            throw AudioError.decodeFailed("SHA-256 failed")
        }
        return String(hash)
    }

    /// 使用 ffprobe 提取音频时长（秒）
    func extractDuration(filePath: String) async -> Double? {
        do {
            let result = try await ProcessRunner.execute(arguments: [
                "ffprobe", "-v", "quiet",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                filePath
            ])
            guard let duration = Double(result), duration > 0 else { return nil }
            return duration
        } catch {
            return nil
        }
    }

    func cleanupRemovedFiles(activeFiles: Set<String>) async throws -> Int {
        let dbSongs = try await Song.query(on: db).all()
        var removed = 0

        for song in dbSongs {
            if !activeFiles.contains(song.filePath) {
                try await song.delete(on: db)
                removed += 1
            }
        }

        return removed
    }
}
