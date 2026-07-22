import Foundation
import OrzAudioKit

struct AuditOptions {
    var source = "keygenmusic"
    var limitPerFormat = 1
    var all = false
    var forceAllFormats = false
    var formats: Set<String>?
}

struct AuditRecord {
    let format: String
    let path: String
    let success: Bool
    let elapsed: TimeInterval
    let message: String
}

struct FormatSummary {
    var total = 0
    var tested = 0
    var succeeded = 0
    var failed = 0
    var elapsed: TimeInterval = 0
}

let supportedExtensions = Set(AudioFormat.allCases.map(\.rawValue))
let fingerprintEligibleExtensions = Set(["mp3", "ogg", "wav", "flac", "m4a", "aac"])

func parseOptions() throws -> AuditOptions {
    var options = AuditOptions()
    var index = 1
    let arguments = CommandLine.arguments

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--source":
            index += 1
            guard index < arguments.count else { throw CliError.missingValue("--source") }
            options.source = arguments[index]
        case "--limit-per-format":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                throw CliError.invalidValue("--limit-per-format")
            }
            options.limitPerFormat = value
        case "--all":
            options.all = true
        case "--force-all-formats":
            options.forceAllFormats = true
        case "--formats":
            index += 1
            guard index < arguments.count else { throw CliError.missingValue("--formats") }
            options.formats = Set(arguments[index].split(separator: ",").map { $0.lowercased() })
        case "--help", "-h":
            printHelp()
            exit(0)
        default:
            throw CliError.unknownArgument(argument)
        }
        index += 1
    }

    return options
}

enum CliError: LocalizedError {
    case missingValue(String)
    case invalidValue(String)
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let argument):
            return "Missing value for \(argument)"
        case .invalidValue(let argument):
            return "Invalid value for \(argument)"
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        }
    }
}

func printHelp() {
    print("""
    Usage:
      swift run OrzFingerprintAudit [--source keygenmusic] [--limit-per-format 1]
      swift run OrzFingerprintAudit --all [--source keygenmusic]
      swift run OrzFingerprintAudit --force-all-formats --formats xm,v2m,sc68 --limit-per-format 3

    This diagnostic tool runs the same production fingerprint policy as the scanner:
    container audio formats are fingerprinted, module/chip formats are skipped.
    Use --force-all-formats only when deliberately testing the slow failure path.
    """)
}

func collectFiles(source: String) throws -> [String: [String]] {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(atPath: source) else {
        throw CliError.invalidValue("--source")
    }

    var filesByFormat: [String: [String]] = [:]
    while let relativePath = enumerator.nextObject() as? String {
        let fullPath = (source as NSString).appendingPathComponent(relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { continue }

        let ext = (relativePath as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { continue }
        filesByFormat[ext, default: []].append(fullPath)
    }

    return filesByFormat.mapValues { $0.sorted() }
}

func selectedFiles(from filesByFormat: [String: [String]], options: AuditOptions) -> [(format: String, path: String)] {
    filesByFormat.keys.sorted().flatMap { format in
        guard options.formats?.contains(format) ?? true else { return [(format: String, path: String)]() }
        guard options.forceAllFormats || fingerprintEligibleExtensions.contains(format) else {
            return [(format: String, path: String)]()
        }
        let files = filesByFormat[format] ?? []
        let selected = options.all ? files : Array(files.prefix(options.limitPerFormat))
        return selected.map { (format, $0) }
    }
}

func fingerprintWithWallTimeout(filePath: String, timeout: TimeInterval) async -> Result<String, Error> {
    await withTaskGroup(of: Result<String, Error>.self) { group in
        group.addTask {
            do {
                let fingerprint = try await AudioFingerprinter().generateFingerprintFromFile(filePath: filePath)
                return .success(fingerprint)
            } catch {
                return .failure(error)
            }
        }

        group.addTask {
            try? await Task.sleep(for: .seconds(timeout))
            return .failure(ProcessRunnerError.timedOut(arguments: ["AudioFingerprinter", filePath], timeout: timeout))
        }

        let result = await group.next()!
        group.cancelAll()
        return result
    }
}

@main
struct OrzFingerprintAudit {
    static func main() async throws {
        let options = try parseOptions()
        let filesByFormat = try collectFiles(source: options.source)
        let files = selectedFiles(from: filesByFormat, options: options)
        let plannedCount = files.count
        let sampleMode = options.all ? "all files" : "first \(options.limitPerFormat) per format"
        let policyMode = options.forceAllFormats ? "force all formats" : "production fingerprint policy"
        let skippedFormats = filesByFormat.keys
            .filter { options.formats?.contains($0) ?? true }
            .filter { !options.forceAllFormats && !fingerprintEligibleExtensions.contains($0) }
            .sorted()

        print("Fingerprint audit source=\(options.source) mode=\(sampleMode), \(policyMode) planned=\(plannedCount)")
        if !skippedFormats.isEmpty {
            print("Skipped by production policy: \(skippedFormats.joined(separator: ", "))")
        }
        print("")

        var summaries = Dictionary(uniqueKeysWithValues: filesByFormat.map { ($0.key, FormatSummary(total: $0.value.count)) })
        var records: [AuditRecord] = []

        for (index, item) in files.enumerated() {
            let shortPath = item.path.replacingOccurrences(of: options.source + "/", with: "")
            let start = Date()
            let result = await fingerprintWithWallTimeout(filePath: item.path, timeout: 35)
            let elapsed = Date().timeIntervalSince(start)

            var summary = summaries[item.format, default: FormatSummary()]
            summary.tested += 1
            summary.elapsed += elapsed

            switch result {
            case .success(let fingerprint):
                summary.succeeded += 1
                records.append(AuditRecord(
                    format: item.format,
                    path: shortPath,
                    success: true,
                    elapsed: elapsed,
                    message: String(fingerprint.prefix(16))
                ))
                print("[\(index + 1)/\(plannedCount)] OK   \(item.format) \(String(format: "%.2fs", elapsed)) \(shortPath)")
            case .failure(let error):
                summary.failed += 1
                records.append(AuditRecord(
                    format: item.format,
                    path: shortPath,
                    success: false,
                    elapsed: elapsed,
                    message: error.localizedDescription
                ))
                print("[\(index + 1)/\(plannedCount)] FAIL \(item.format) \(String(format: "%.2fs", elapsed)) \(shortPath) :: \(error.localizedDescription)")
            }

            summaries[item.format] = summary
        }

        print("")
        print("| Format | Total | Tested | OK | Failed | Avg |")
        print("|---|---:|---:|---:|---:|---:|")
        for format in summaries.keys.sorted() {
            let summary = summaries[format] ?? FormatSummary()
            guard summary.tested > 0 else { continue }
            let avg = summary.elapsed / Double(summary.tested)
            print("| \(format) | \(summary.total) | \(summary.tested) | \(summary.succeeded) | \(summary.failed) | \(String(format: "%.2fs", avg)) |")
        }

        let failed = records.filter { !$0.success }
        if !failed.isEmpty {
            print("")
            print("Failures:")
            for record in failed.prefix(50) {
                print("- \(record.format) \(String(format: "%.2fs", record.elapsed)) \(record.path): \(record.message)")
            }
            if failed.count > 50 {
                print("- ... \(failed.count - 50) more")
            }
        }

        print("")
        print("Result: tested=\(records.count) succeeded=\(records.filter(\.success).count) failed=\(failed.count)")
    }
}
