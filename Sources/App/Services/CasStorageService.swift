import Foundation
import OrzAudioKit

/// Content-Addressed Storage — 内容寻址存储服务
///
/// 所有音频文件按 SHA-256 哈希存储，路径格式：
///   {root}/{hash[:2]}/{hash}.{ext}
///
/// 文件导入后永不移动，天然去重。DB 不存路径，只存 hash + 格式。
/// 文件原样存储，不做转换。播放时由服务端按需处理编码兼容问题。
public struct CasStorageService: Sendable {
    public struct InspectedFile: Sendable {
        public let sha256: String
        public let ext: String
        public let fileSize: Int
    }

    public struct StoreResult: Sendable {
        public let sha256: String
        public let ext: String
        public let fileSize: Int
        public let created: Bool
    }

    /// CAS 根目录（如 ./data/music）
    public let root: String

    private let queue: DispatchQueue  // 串行队列，防止并发目录创建竞争

    public init(root: String) {
        self.root = (root as NSString).standardizingPath
        self.queue = DispatchQueue(label: "com.orzplayer.cas", qos: .utility)
    }

    // MARK: - Public API

    /// 将源文件导入 CAS，返回内容标识
    ///
    /// - Parameter sourcePath: 源文件绝对路径
    /// - Returns: Content identity and source file size without mutating CAS.
    public func inspect(sourcePath: String) async throws -> InspectedFile {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let ext = sourceURL.pathExtension.lowercased()
        let sha256 = try await computeSHA256(filePath: sourcePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: sourcePath)
        let fileSize = (attributes[.size] as? Int) ?? 0
        return InspectedFile(sha256: sha256, ext: ext, fileSize: fileSize)
    }

    /// Store a previously inspected stable source and report whether this call
    /// created the CAS object. Callers can use `created` for failure cleanup.
    public func store(sourcePath: String, inspected: InspectedFile) throws -> StoreResult {
        let destPath = resolve(sha256: inspected.sha256, format: inspected.ext)

        let fm = FileManager.default
        let created = try queue.sync {
            if !fm.fileExists(atPath: destPath) {
                let dir = (destPath as NSString).deletingLastPathComponent
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let stagedPath = (dir as NSString)
                    .appendingPathComponent(".orz-cas-\(UUID().uuidString).tmp")
                defer { try? fm.removeItem(atPath: stagedPath) }
                try fm.copyItem(atPath: sourcePath, toPath: stagedPath)
                do {
                    try fm.moveItem(atPath: stagedPath, toPath: destPath)
                    return true
                } catch where fm.fileExists(atPath: destPath) {
                    // Another process may have published the same object.
                    return false
                }
            }
            return false
        }

        let attrs = try fm.attributesOfItem(atPath: destPath)
        let fileSize = (attrs[.size] as? Int) ?? 0
        return StoreResult(
            sha256: inspected.sha256,
            ext: inspected.ext,
            fileSize: fileSize,
            created: created
        )
    }

    public func store(sourcePath: String) async throws -> StoreResult {
        let inspected = try await inspect(sourcePath: sourcePath)
        return try store(sourcePath: sourcePath, inspected: inspected)
    }

    /// 根据 SHA-256 和格式构建完整存储路径
    public func resolve(sha256: String, format: String) -> String {
        let prefix = String(sha256.prefix(2))
        let fileName = "\(sha256).\(format)"
        return URL(fileURLWithPath: root)
            .appendingPathComponent(prefix)
            .appendingPathComponent(fileName)
            .path
    }

    /// 删除 CAS 中的文件
    public func delete(sha256: String, format: String) throws {
        let path = resolve(sha256: sha256, format: format)
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
    }

    /// 检查 CAS 中是否存在指定 hash 的文件
    public func contains(sha256: String, format: String) -> Bool {
        FileManager.default.fileExists(atPath: resolve(sha256: sha256, format: format))
    }

    // MARK: - SHA-256

    /// 计算文件的 SHA-256 哈希。
    /// macOS 提供 `shasum -a 256`，Linux 运行镜像提供 `sha256sum`。
    private func computeSHA256(filePath: String) async throws -> String {
        #if os(Linux)
        let arguments = ["sha256sum", filePath]
        #else
        let arguments = ["shasum", "-a", "256", filePath]
        #endif
        let result = try await ProcessRunner.execute(arguments: arguments)
        guard let hash = result.split(separator: " ").first else {
            throw CasError.sha256Failed(path: filePath)
        }
        return String(hash)
    }
}

// MARK: - Errors

public enum CasError: LocalizedError {
    case sha256Failed(path: String)
    case fileNotFound(sha256: String, format: String)

    public var errorDescription: String? {
        switch self {
        case .sha256Failed(let path):
            return "SHA-256 computation failed for: \(path)"
        case .fileNotFound(let sha256, let format):
            return "File not found in CAS: \(sha256).\(format)"
        }
    }
}
