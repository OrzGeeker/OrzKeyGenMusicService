import Foundation
import Vapor
import Fluent
import OrzAudioKit

/// 音乐文件扫描服务（CAS 版）
///
/// 负责：
/// 1. 扫描一个或多个源目录，识别所有支持的音频格式
/// 2. 将文件导入 CAS（按 SHA-256 内容寻址存储）
/// 3. SHA-256 去重
/// 4. 创建 Song 记录（不含 file_path）
public struct MusicScannerService {

    public struct ScanResult: Content {
        public let totalScanned: Int
        public let songsCreated: Int
        public let duplicatesSkipped: Int
        public let elapsed: String

        public init(totalScanned: Int, songsCreated: Int, duplicatesSkipped: Int, elapsed: String) {
            self.totalScanned = totalScanned
            self.songsCreated = songsCreated
            self.duplicatesSkipped = duplicatesSkipped
            self.elapsed = elapsed
        }
    }

    private let sourcePaths: [String]
    private let cas: CasStorageService
    private let db: any Database
    private let fileManager = FileManager.default

    public init(sourcePaths: [String], cas: CasStorageService, db: any Database) {
        self.sourcePaths = sourcePaths
        self.cas = cas
        self.db = db
    }

    /// 执行全量扫描
    public func scan() async throws -> ScanResult {
        let start = Date()
        var totalScanned = 0
        var songsCreated = 0
        var duplicatesSkipped = 0

        for sourcePath in sourcePaths {
            let result = try await scanSource(sourcePath: sourcePath)
            totalScanned += result.scanned
            songsCreated += result.created
            duplicatesSkipped += result.skipped
        }

        // 不再需要 cleanupRemovedFiles — CAS 模式下 DB 是 append-only 的元数据仓库，
        // 源文件可以随时删除，不影响已有 Song 记录。
        // 播放永远从 CAS 读取。

        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(start))

        return ScanResult(
            totalScanned: totalScanned,
            songsCreated: songsCreated,
            duplicatesSkipped: duplicatesSkipped,
            elapsed: elapsed
        )
    }

    // MARK: - Source Scanner

    private struct SourceScanResult {
        let scanned: Int
        let created: Int
        let skipped: Int
    }

    private func scanSource(sourcePath: String) async throws -> SourceScanResult {
        var scanned = 0
        var created = 0
        var skipped = 0

        guard let enumerator = fileManager.enumerator(atPath: sourcePath) else {
            return SourceScanResult(scanned: 0, created: 0, skipped: 0)
        }

        while let relativePath = enumerator.nextObject() as? String {
            let fullPath = (sourcePath as NSString).appendingPathComponent(relativePath)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }

            let ext = (relativePath as NSString).pathExtension.lowercased()
            guard AudioFormat.from(fileExtension: ext) != nil else { continue }

            scanned += 1

            do {
                // 1. 导入 CAS（复制到内容寻址存储）
                let (sha256, _, fileSize) = try await cas.store(sourcePath: fullPath)

                // 2. SHA-256 去重
                if try await Song.query(on: db).filter("sha256", .equal, sha256).first() != nil {
                    skipped += 1
                    continue
                }

                // 3. 解析元数据
                let info = parseMetadata(relativePath: relativePath, fileName: (relativePath as NSString).lastPathComponent)

                // 4. Upsert Artist
                let artist = try await upsertArtist(name: info.artistName)

                // 5. 创建 Song
                let song = Song(
                    title: info.songTitle,
                    sha256: sha256,
                    fileFormat: ext,
                    fileSize: fileSize
                )
                song.$artist.id = artist?.id
                song.duration = await extractDuration(filePath: fullPath)

                // 尝试生成音频指纹（可选，静默跳过失败）
                if let fp = try? await generateFingerprint(filePath: fullPath) {
                    song.audioFingerprint = fp
                }

                try await song.create(on: db)
                created += 1

            } catch {
                // 单个文件失败不影响扫描继续
                continue
            }
        }

        return SourceScanResult(scanned: scanned, created: created, skipped: skipped)
    }

    // MARK: - Metadata Parsing

    struct ParsedMetadata {
        let artistName: String
        let songTitle: String
        let trackType: String?
    }

    func parseMetadata(relativePath: String, fileName: String) -> ParsedMetadata {
        let name = (fileName as NSString).deletingPathExtension

        // 获取父目录名作为 artist
        let parentDir = ((relativePath as NSString).deletingLastPathComponent as NSString).lastPathComponent

        let artistFromDir: String
        if parentDir == "KEYGENMUSiC MusicPack" || parentDir == "!Others" || parentDir == "." || parentDir.hasPrefix(".") {
            artistFromDir = "Unknown"
        } else {
            artistFromDir = parentDir
        }

        var songTitle = name
        var trackType: String? = nil
        var artistName = artistFromDir

        if let range = name.range(of: " - ") {
            let prefix = String(name[..<range.lowerBound])
            var suffix = String(name[range.upperBound...])

            if prefix.count > 0 && prefix.count < 20 {
                if artistFromDir == "Unknown" || !name.hasPrefix(artistFromDir) {
                    artistName = prefix
                    suffix = String(name[range.upperBound...])
                }
            }

            songTitle = suffix
        }

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
            songTitle: songTitle.isEmpty ? name : songTitle,
            trackType: trackType
        )
    }

    // MARK: - Helpers

    func upsertArtist(name: String) async throws -> Artist? {
        if let existing = try await Artist.query(on: db).filter("name", .equal, name).first() {
            return existing
        }
        let artist = Artist(name: name)
        try await artist.create(on: db)
        return artist
    }

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

    func generateFingerprint(filePath: String) async throws -> String? {
        let fingerprinter = AudioFingerprinter()
        return try? await fingerprinter.generateFingerprintFromFile(filePath: filePath)
    }
}
