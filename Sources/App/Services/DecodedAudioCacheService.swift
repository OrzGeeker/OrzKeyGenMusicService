import Foundation
import OrzAudioKit

public struct DecodedAudioCacheOutcome: Sendable {
    public let path: String
    public let cacheHit: Bool
    public let queueMilliseconds: Double
    public let decodeMilliseconds: Double
    public let outputBytes: Int64
}

public struct DecodedAudioCacheService: Sendable {
    public let cas: CasStorageService
    public let coordinator: DecodeCacheCoordinator

    public init(cas: CasStorageService, coordinator: DecodeCacheCoordinator) {
        self.cas = cas
        self.coordinator = coordinator
    }

    public func prepare(
        originalPath: String,
        sha256: String,
        format: AudioFormat,
        subsong: Int = 0,
        onFailure: (@Sendable (_ queueMilliseconds: Double, _ decodeMilliseconds: Double, _ error: any Error) -> Void)? = nil
    ) async throws -> DecodedAudioCacheOutcome {
        let cacheDirectory = "\(cas.root)/.cache/wav"
        let cachePath = Self.cachePath(
            cacheDirectory: cacheDirectory,
            sha256: sha256,
            format: format,
            subsong: subsong
        )
        let fileManager = FileManager.default
        if Self.isValidPCMCache(at: cachePath, fileManager: fileManager) {
            return .init(
                path: cachePath,
                cacheHit: true,
                queueMilliseconds: 0,
                decodeMilliseconds: 0,
                outputBytes: Self.fileSize(at: cachePath, fileManager: fileManager)
            )
        }

        let key = DecodeCacheKey(
            sha256: sha256,
            decoderFingerprint: AudioDecoder.cacheFingerprint,
            format: format.rawValue,
            sampleRate: "native",
            channels: "native",
            subsong: subsong
        )
        let result = try await coordinator.run(key: key, operation: {
            let manager = FileManager()
            if Self.isValidPCMCache(at: cachePath, fileManager: manager) { return cachePath }
            if manager.fileExists(atPath: cachePath) {
                try? manager.removeItem(atPath: cachePath)
            }
            try manager.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)
            try await AudioEngine().decodeToWAVFile(
                filePath: originalPath,
                format: format,
                destinationPath: cachePath,
                subsong: subsong
            )
            guard Self.isValidPCMCache(at: cachePath, fileManager: manager) else {
                try? manager.removeItem(atPath: cachePath)
                throw AudioError.decodeFailed("Decoder did not commit a valid PCM WAV cache")
            }
            return cachePath
        }, onFailure: onFailure)

        return .init(
            path: result.path,
            cacheHit: false,
            queueMilliseconds: result.queueMilliseconds,
            decodeMilliseconds: result.decodeMilliseconds,
            outputBytes: Self.fileSize(at: result.path, fileManager: fileManager)
        )
    }

    public static func cachePath(
        cacheDirectory: String,
        sha256: String,
        format: AudioFormat,
        subsong: Int
    ) -> String {
        "\(cacheDirectory)/\(sha256)-\(AudioDecoder.cacheFingerprint)-\(format.rawValue)-rate-native-ch-native-sub-\(subsong).wav"
    }

    public static func isValidPCMCache(at path: String, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              (try? WAVFile.parse(data, includeSamples: false).encoding) == .pcm else {
            return false
        }
        return true
    }

    private static func fileSize(at path: String, fileManager: FileManager) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
