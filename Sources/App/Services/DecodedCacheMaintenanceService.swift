import Foundation
import OrzAudioKit

public enum DecodedCacheMaintenanceError: Error {
    case unsafeCacheDirectory(String)
    case invalidMaximumBytes
}

public struct DecodedCacheMaintenanceOptions: Sendable {
    public var maximumBytes: Int64?
    public var removeOldFingerprints: Bool
    public var dryRun: Bool
    public var minimumAgeSeconds: TimeInterval

    public init(
        maximumBytes: Int64? = nil,
        removeOldFingerprints: Bool = false,
        dryRun: Bool = true,
        minimumAgeSeconds: TimeInterval = 300
    ) {
        self.maximumBytes = maximumBytes
        self.removeOldFingerprints = removeOldFingerprints
        self.dryRun = dryRun
        self.minimumAgeSeconds = minimumAgeSeconds
    }
}

public struct DecodedCacheFingerprintUsage: Sendable {
    public let fingerprint: String
    public let files: Int
    public let bytes: Int64
}

public struct DecodedCacheMaintenanceSummary: Sendable {
    public let cacheDirectory: String
    public var files = 0
    public var totalBytes: Int64 = 0
    public var fingerprintUsage: [DecodedCacheFingerprintUsage] = []
    public var selectedFiles = 0
    public var selectedBytes: Int64 = 0
    public var deletedFiles = 0
    public var deletedBytes: Int64 = 0
    public var busyFiles = 0
    public var tooRecentFiles = 0
    public var malformedFiles = 0
    public var failures: [String] = []
}

public struct DecodedCacheMaintenanceService: Sendable {
    private struct Entry {
        let url: URL
        let size: Int64
        let modifiedAt: Date
        let fingerprint: String
        let recognized: Bool
    }

    public let cacheDirectory: URL

    public init(casRoot: String) throws {
        let root = URL(fileURLWithPath: casRoot, isDirectory: true).standardizedFileURL
        let candidate = root.appendingPathComponent(".cache/wav", isDirectory: true).standardizedFileURL
        let rootResolved = root.resolvingSymlinksInPath().path
        let parentResolved = candidate.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard candidate.lastPathComponent == "wav",
              candidate.deletingLastPathComponent().lastPathComponent == ".cache",
              parentResolved == URL(fileURLWithPath: rootResolved).appendingPathComponent(".cache").standardizedFileURL.path else {
            throw DecodedCacheMaintenanceError.unsafeCacheDirectory(candidate.path)
        }
        self.cacheDirectory = candidate
    }

    public func run(options: DecodedCacheMaintenanceOptions, now: Date = Date()) throws -> DecodedCacheMaintenanceSummary {
        if let maximumBytes = options.maximumBytes, maximumBytes < 0 {
            throw DecodedCacheMaintenanceError.invalidMaximumBytes
        }
        var summary = DecodedCacheMaintenanceSummary(cacheDirectory: cacheDirectory.path)
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return summary }
        try validateResolvedDirectory()

        let entries = try loadEntries(summary: &summary)
        summary.files = entries.count
        summary.totalBytes = entries.reduce(0) { $0 + $1.size }
        summary.fingerprintUsage = Dictionary(grouping: entries, by: \.fingerprint)
            .map { fingerprint, values in
                .init(
                    fingerprint: fingerprint,
                    files: values.count,
                    bytes: values.reduce(0) { $0 + $1.size }
                )
            }
            .sorted { $0.fingerprint < $1.fingerprint }

        let currentFingerprint = AudioDecoder.cacheFingerprint
        var selected: [Entry] = []
        if options.removeOldFingerprints {
            selected.append(contentsOf: entries.filter {
                $0.recognized && $0.fingerprint != currentFingerprint
            })
        }
        if let maximumBytes = options.maximumBytes {
            var remaining = summary.totalBytes - selected.reduce(0) { $0 + $1.size }
            let alreadySelected = Set(selected.map(\.url.path))
            for entry in entries
                .filter({ $0.recognized && !alreadySelected.contains($0.url.path) })
                .sorted(by: { $0.modifiedAt < $1.modifiedAt })
            where remaining > maximumBytes {
                selected.append(entry)
                remaining -= entry.size
            }
        }

        for entry in selected {
            guard now.timeIntervalSince(entry.modifiedAt) >= options.minimumAgeSeconds else {
                summary.tooRecentFiles += 1
                continue
            }
            let lease: DecodedCacheFileLease
            do {
                lease = try DecodedCacheFileLease.tryAcquireExclusive(for: entry.url.path)
            } catch DecodedCacheFileLeaseError.busy {
                summary.busyFiles += 1
                continue
            } catch {
                summary.failures.append("\(entry.url.lastPathComponent): lock failed")
                continue
            }
            defer { lease.release() }
            summary.selectedFiles += 1
            summary.selectedBytes += entry.size
            guard !options.dryRun else { continue }
            do {
                try FileManager.default.removeItem(at: entry.url)
                summary.deletedFiles += 1
                summary.deletedBytes += entry.size
            } catch {
                summary.failures.append("\(entry.url.lastPathComponent): delete failed")
            }
        }
        return summary
    }

    private func validateResolvedDirectory() throws {
        let resolved = cacheDirectory.resolvingSymlinksInPath()
        let expected = cacheDirectory.standardizedFileURL
        guard resolved.path == expected.path else {
            throw DecodedCacheMaintenanceError.unsafeCacheDirectory(resolved.path)
        }
    }

    private func loadEntries(summary: inout DecodedCacheMaintenanceSummary) throws -> [Entry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).compactMap { url in
            guard url.pathExtension == "wav",
                  url.deletingLastPathComponent().standardizedFileURL.path == cacheDirectory.path,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                if url.pathExtension == "wav" { summary.malformedFiles += 1 }
                return nil
            }
            let parsedFingerprint = Self.fingerprint(from: url.lastPathComponent)
            if parsedFingerprint == nil { summary.malformedFiles += 1 }
            return Entry(
                url: url,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast,
                fingerprint: parsedFingerprint ?? "unrecognized",
                recognized: parsedFingerprint != nil
            )
        }
    }

    public static func fingerprint(from filename: String) -> String? {
        guard filename.hasSuffix(".wav"),
              filename.prefix(64).count == 64,
              filename.prefix(64).allSatisfy(\.isHexDigit) else {
            return nil
        }
        if filename.count == 68 { return "legacy-unversioned" }
        guard filename.count > 68,
              filename[filename.index(filename.startIndex, offsetBy: 64)] == "-" else { return nil }
        let remainderStart = filename.index(filename.startIndex, offsetBy: 65)
        let remainder = String(filename[remainderStart...].dropLast(4))
        guard let range = remainder.range(of: "-rate-native-ch-native-sub-", options: .backwards),
              let formatSeparator = remainder[..<range.lowerBound].lastIndex(of: "-") else {
            return nil
        }
        let fingerprint = remainder[..<formatSeparator]
        if remainder.hasPrefix("decoder-v") {
            return "legacy-\(remainder[..<range.lowerBound])"
        }
        return fingerprint.isEmpty ? nil : String(fingerprint)
    }
}
