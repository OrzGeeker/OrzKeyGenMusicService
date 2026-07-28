import Foundation
import Vapor
import Fluent
import OrzAudioKit

/// 音乐文件扫描服务（CAS 版）
///
/// 负责：
/// 1. 扫描配置的源目录，识别所有支持的音频格式
/// 2. 通过 MusicImportService 导入、去重并创建 Song
public struct MusicScannerService {

    public struct ScanResult: Content {
        public let totalScanned: Int
        public let songsCreated: Int
        public let duplicatesSkipped: Int
        public let failedFiles: Int
        public let elapsed: String

        public init(totalScanned: Int, songsCreated: Int, duplicatesSkipped: Int, failedFiles: Int, elapsed: String) {
            self.totalScanned = totalScanned
            self.songsCreated = songsCreated
            self.duplicatesSkipped = duplicatesSkipped
            self.failedFiles = failedFiles
            self.elapsed = elapsed
        }
    }

    private let sourceRoot: String
    private let importer: MusicImportService
    private let fileManager = FileManager.default

    public init(sourceRoot: String, cas: CasStorageService, db: any Database) {
        self.sourceRoot = sourceRoot
        self.importer = MusicImportService(cas: cas, db: db)
    }

    /// 执行全量扫描
    public func scan() async throws -> ScanResult {
        let start = Date()
        var totalScanned = 0
        var songsCreated = 0
        var duplicatesSkipped = 0
        var failedFiles = 0

        let validatedRoot = try validateSourceRoot()
        let result = try await scanSource(sourceRoot: validatedRoot)
        totalScanned += result.scanned
        songsCreated += result.created
        duplicatesSkipped += result.skipped
        failedFiles += result.failed

        // 不再需要 cleanupRemovedFiles — CAS 模式下 DB 是 append-only 的元数据仓库，
        // 源文件可以随时删除，不影响已有 Song 记录。
        // 播放永远从 CAS 读取。

        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(start))

        return ScanResult(
            totalScanned: totalScanned,
            songsCreated: songsCreated,
            duplicatesSkipped: duplicatesSkipped,
            failedFiles: failedFiles,
            elapsed: elapsed
        )
    }

    // MARK: - Source Scanner

    private struct SourceScanResult {
        let scanned: Int
        let created: Int
        let skipped: Int
        let failed: Int
    }

    private func validateSourceRoot() throws -> URL {
        let configuredRoot = URL(fileURLWithPath: sourceRoot).standardizedFileURL

        do {
            let values = try configuredRoot.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw ScanAPIError.rootUnavailable("SCAN_ROOT must not be a symbolic link")
            }
            guard values.isDirectory == true else {
                throw ScanAPIError.rootUnavailable("SCAN_ROOT is not a directory")
            }
            guard fileManager.isReadableFile(atPath: configuredRoot.path) else {
                throw ScanAPIError.rootUnavailable("SCAN_ROOT is not readable")
            }
        } catch let error as ScanAPIError {
            throw error
        } catch {
            throw ScanAPIError.rootUnavailable("SCAN_ROOT does not exist or cannot be accessed")
        }

        return configuredRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    private func scanSource(sourceRoot: URL) async throws -> SourceScanResult {
        var scanned = 0
        var created = 0
        var skipped = 0
        var failed = 0

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw ScanAPIError.rootUnavailable("SCAN_ROOT cannot be enumerated")
        }

        while let candidate = enumerator.nextObject() as? URL {
            guard let values = try? candidate.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }

            let standardizedCandidate = candidate.standardizedFileURL
            guard isContained(standardizedCandidate, in: sourceRoot) else { continue }

            let resolvedCandidate = standardizedCandidate
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard isContained(resolvedCandidate, in: sourceRoot) else { continue }

            let relativePath = String(
                standardizedCandidate.path.dropFirst(sourceRoot.path.count + 1)
            )
            let fullPath = standardizedCandidate.path

            let ext = (relativePath as NSString).pathExtension.lowercased()
            guard AudioFormat.from(fileExtension: ext) != nil else { continue }

            scanned += 1

            do {
                switch try await importer.importFile(
                    sourcePath: fullPath,
                    relativePath: relativePath
                ) {
                case .created:
                    created += 1
                case .duplicate:
                    skipped += 1
                }
            } catch {
                // 单个文件失败不影响扫描继续
                failed += 1
                continue
            }
        }

        return SourceScanResult(scanned: scanned, created: created, skipped: skipped, failed: failed)
    }

    private func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(rootPrefix)
    }

}
