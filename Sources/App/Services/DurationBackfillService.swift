import Fluent
import Foundation
import OrzAudioKit

public struct DurationBackfillOptions: Sendable {
    public var batchSize: Int
    public var concurrency: Int
    public var limit: Int?
    public var dryRun: Bool

    public init(batchSize: Int = 50, concurrency: Int = 2, limit: Int? = nil, dryRun: Bool = false) {
        self.batchSize = batchSize
        self.concurrency = concurrency
        self.limit = limit
        self.dryRun = dryRun
    }
}

public struct DurationBackfillSummary: Sendable {
    public var selected = 0
    public var updated = 0
    public var missingFiles = 0
    public var probeFailures = 0
    public var failures: [DurationBackfillFailure] = []
}

public struct DurationBackfillFailure: Sendable {
    public let id: UUID?
    public let format: String
    public let reason: String
}

public struct DurationBackfillService: Sendable {
    private let database: any Database
    private let cas: CasStorageService

    public init(database: any Database, cas: CasStorageService) {
        self.database = database
        self.cas = cas
    }

    public func run(options: DurationBackfillOptions) async throws -> DurationBackfillSummary {
        precondition(options.batchSize > 0)
        precondition(options.concurrency > 0)

        var summary = DurationBackfillSummary()
        var failedOffset = 0

        while options.limit.map({ summary.selected < $0 }) ?? true {
            let remaining = options.limit.map { max(0, $0 - summary.selected) } ?? options.batchSize
            let requested = min(options.batchSize, remaining)
            guard requested > 0 else { break }

            let songs = try await Song.query(on: database)
                .filter(\.$duration == nil)
                .sort(\.$id, .ascending)
                .range(failedOffset..<(failedOffset + requested))
                .all()
            guard !songs.isEmpty else { break }

            summary.selected += songs.count
            if options.dryRun {
                failedOffset += songs.count
                continue
            }

            for start in stride(from: 0, to: songs.count, by: options.concurrency) {
                let batch = Array(songs[start..<min(start + options.concurrency, songs.count)])
                let results = await withTaskGroup(of: (Song, ProbeResult).self) { group in
                    for song in batch {
                        group.addTask {
                            let path = cas.resolve(sha256: song.sha256, format: song.fileFormat)
                            guard FileManager.default.fileExists(atPath: path) else {
                                return (song, .missingFile)
                            }
                            guard let duration = await AudioDurationProbe.duration(
                                filePath: path,
                                format: song.fileFormat
                            ) else {
                                return (song, .failed)
                            }
                            return (song, .duration(duration))
                        }
                    }
                    var values: [(Song, ProbeResult)] = []
                    for await result in group { values.append(result) }
                    return values
                }

                for (song, result) in results {
                    switch result {
                    case .duration(let duration):
                        song.duration = duration
                        try await song.update(on: database)
                        summary.updated += 1
                    case .missingFile:
                        summary.missingFiles += 1
                        failedOffset += 1
                        summary.failures.append(.init(
                            id: song.id,
                            format: song.fileFormat,
                            reason: "CAS file not found"
                        ))
                    case .failed:
                        summary.probeFailures += 1
                        failedOffset += 1
                        summary.failures.append(.init(
                            id: song.id,
                            format: song.fileFormat,
                            reason: "duration probe failed or timed out"
                        ))
                    }
                }
            }
        }

        return summary
    }

    private enum ProbeResult: Sendable {
        case duration(Double)
        case missingFile
        case failed
    }
}
