import Foundation
import Fluent
import OrzAudioKit

/// Shared import pipeline for server-side scans and uploaded files.
///
/// CAS remains the durable source of truth for file bytes. Database writes are
/// transactional, and the database SHA-256 unique constraint is the final
/// duplicate guard when imports race.
struct MusicImportService {
    private actor ImportCoordinator {
        static let shared = ImportCoordinator()

        private var activeHashes: Set<String> = []
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        func acquire(_ sha256: String) async {
            guard activeHashes.contains(sha256) else {
                activeHashes.insert(sha256)
                return
            }
            await withCheckedContinuation { continuation in
                waiters[sha256, default: []].append(continuation)
            }
        }

        func release(_ sha256: String) {
            if var queued = waiters[sha256], !queued.isEmpty {
                let next = queued.removeFirst()
                waiters[sha256] = queued.isEmpty ? nil : queued
                next.resume()
            } else {
                activeHashes.remove(sha256)
            }
        }
    }

    struct ParsedMetadata {
        let artistName: String
        let songTitle: String
        let trackType: String?
    }

    enum ImportResult {
        case created(Song)
        case duplicate(Song)
    }

    private let cas: CasStorageService
    private let db: any Database
    private let afterCASStore: (@Sendable (CasStorageService.StoreResult) throws -> Void)?

    init(cas: CasStorageService, db: any Database) {
        self.init(cas: cas, db: db, afterCASStore: nil)
    }

    init(
        cas: CasStorageService,
        db: any Database,
        afterCASStore: (@Sendable (CasStorageService.StoreResult) throws -> Void)?
    ) {
        self.cas = cas
        self.db = db
        self.afterCASStore = afterCASStore
    }

    func importFile(
        sourcePath: String,
        relativePath: String? = nil,
        artist explicitArtist: String? = nil,
        title explicitTitle: String? = nil
    ) async throws -> ImportResult {
        let sourceExtension = (sourcePath as NSString).pathExtension.lowercased()
        guard let format = AudioFormat.from(fileExtension: sourceExtension) else {
            throw MusicImportError.unsupportedFormat(sourceExtension)
        }

        let displayPath = relativePath ?? (sourcePath as NSString).lastPathComponent
        let fileName = (displayPath as NSString).lastPathComponent
        let metadata = parseMetadata(relativePath: displayPath, fileName: fileName)
        let artistName = normalized(explicitArtist) ?? metadata.artistName
        let songTitle = normalized(explicitTitle) ?? metadata.songTitle

        let inspected = try await cas.inspect(sourcePath: sourcePath)
        await ImportCoordinator.shared.acquire(inspected.sha256)

        do {
            let result = try await importInspectedFile(
                sourcePath: sourcePath,
                inspected: inspected,
                format: format,
                artistName: artistName,
                songTitle: songTitle
            )
            await ImportCoordinator.shared.release(inspected.sha256)
            return result
        } catch {
            await ImportCoordinator.shared.release(inspected.sha256)
            throw error
        }
    }

    private func importInspectedFile(
        sourcePath: String,
        inspected: CasStorageService.InspectedFile,
        format: AudioFormat,
        artistName: String,
        songTitle: String
    ) async throws -> ImportResult {
        if let existing = try await findSong(sha256: inspected.sha256, on: db) {
            return .duplicate(existing)
        }

        let duration = await AudioDurationProbe.duration(filePath: sourcePath, format: format.rawValue)
        let fingerprint: String?
        if shouldGenerateAudioFingerprint(format: format) {
            fingerprint = try? await AudioFingerprinter()
                .generateFingerprintFromFile(filePath: sourcePath)
        } else {
            fingerprint = nil
        }
        // Artist upsert happens outside the song transaction so a unique-name
        // race can be recovered on PostgreSQL (where a failed statement aborts
        // the current transaction).
        let artist = try await upsertArtist(name: artistName, on: db)

        let stored = try cas.store(sourcePath: sourcePath, inspected: inspected)
        do {
            try afterCASStore?(stored)
            return try await db.transaction { transaction in
                if let existing = try await findSong(sha256: inspected.sha256, on: transaction) {
                    return .duplicate(existing)
                }

                let song = Song(
                    title: songTitle,
                    sha256: inspected.sha256,
                    fileFormat: format.rawValue,
                    fileSize: stored.fileSize,
                    duration: duration
                )
                song.$artist.id = try artist.requireID()
                song.audioFingerprint = fingerprint
                try await song.create(on: transaction)
                return .created(song)
            }
        } catch {
            // A concurrent transaction may have inserted this SHA-256 after the
            // preflight query. Treat the database unique constraint as the final
            // duplicate decision without hiding unrelated failures.
            if let existing = try? await findSong(sha256: inspected.sha256, on: db) {
                return .duplicate(existing)
            }
            if stored.created {
                try? cas.delete(sha256: inspected.sha256, format: inspected.ext)
            }
            throw error
        }
    }

    func parseMetadata(relativePath: String, fileName: String) -> ParsedMetadata {
        let name = (fileName as NSString).deletingPathExtension
        let parentDir = ((relativePath as NSString).deletingLastPathComponent as NSString)
            .lastPathComponent

        let artistFromDirectory: String
        if parentDir.isEmpty
            || parentDir == "KEYGENMUSiC MusicPack"
            || parentDir == "!Others"
            || parentDir == "."
            || parentDir.hasPrefix(".")
        {
            artistFromDirectory = "Unknown"
        } else {
            artistFromDirectory = parentDir
        }

        var songTitle = name
        var trackType: String?
        var artistName = artistFromDirectory

        if let range = name.range(of: " - ") {
            let prefix = String(name[..<range.lowerBound])
            let suffix = String(name[range.upperBound...])
            if !prefix.isEmpty,
               prefix.count < 20,
               artistFromDirectory == "Unknown" || !name.hasPrefix(artistFromDirectory) {
                artistName = prefix
            }
            songTitle = suffix
        }

        let typeKeywords = [
            "intro", "kg", "crk", "trn", "trainer", "installer",
            "keygen", "activator", "launcher",
        ]
        for keyword in typeKeywords {
            if let range = songTitle.range(
                of: "\\b\(keyword)\\b",
                options: [.regularExpression, .caseInsensitive]
            ) {
                trackType = keyword
                var trimCharacters = CharacterSet.whitespacesAndNewlines
                trimCharacters.formUnion(.punctuationCharacters)
                songTitle = String(songTitle[..<range.lowerBound])
                    .trimmingCharacters(in: trimCharacters)
                break
            }
        }

        return ParsedMetadata(
            artistName: artistName,
            songTitle: songTitle.isEmpty ? name : songTitle,
            trackType: trackType
        )
    }

    func shouldGenerateAudioFingerprint(format: AudioFormat) -> Bool {
        switch format {
        case .mp3, .ogg, .wav, .flac, .m4a, .aac:
            return true
        case .xm, .mod, .it, .s3m, .mo3, .mtm,
             .mid, .nsf, .spc, .sid, .sc68,
             .hsc, .ym, .ahx, .amd, .fc13, .fc14,
             .sap, .rad, .d00, .v2m, .bp:
            return false
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func findSong(sha256: String, on database: any Database) async throws -> Song? {
        try await Song.query(on: database)
            .filter(\.$sha256 == sha256)
            .first()
    }

    private func upsertArtist(name: String, on database: any Database) async throws -> Artist {
        if let existing = try await Artist.query(on: database)
            .filter(\.$name == name)
            .first() {
            return existing
        }

        let artist = Artist(name: name)
        do {
            try await artist.create(on: database)
            return artist
        } catch {
            // Artist names are unique. A concurrent import may have created the
            // same artist; recover it instead of failing the song import.
            if let existing = try? await Artist.query(on: database)
                .filter(\.$name == name)
                .first() {
                return existing
            }
            throw error
        }
    }
}

enum MusicImportError: LocalizedError {
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fileExtension):
            return "Unsupported file format: \(fileExtension)"
        }
    }
}
