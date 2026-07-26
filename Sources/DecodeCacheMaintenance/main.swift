import App
import Foundation
import Vapor

private struct CLIOptions {
    var maximumBytes: Int64?
    var removeOldFingerprints = false
    var apply = false
    var minimumAgeSeconds: TimeInterval = 300
}

private enum CLIError: LocalizedError {
    case missingValue(String), invalidValue(String), unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let value): "Missing value for \(value)"
        case .invalidValue(let value): "Invalid value for \(value)"
        case .unknownArgument(let value): "Unknown argument: \(value)"
        }
    }
}

private func parseOptions() throws -> CLIOptions {
    var options = CLIOptions()
    var index = 1
    let arguments = CommandLine.arguments
    func value(_ name: String) throws -> String {
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(name) }
        return arguments[index]
    }
    while index < arguments.count {
        switch arguments[index] {
        case "--max-bytes":
            guard let bytes = Int64(try value("--max-bytes")), bytes >= 0 else {
                throw CLIError.invalidValue("--max-bytes")
            }
            options.maximumBytes = bytes
        case "--remove-old-fingerprints": options.removeOldFingerprints = true
        case "--minimum-age-seconds":
            guard let seconds = TimeInterval(try value("--minimum-age-seconds")), seconds >= 0 else {
                throw CLIError.invalidValue("--minimum-age-seconds")
            }
            options.minimumAgeSeconds = seconds
        case "--apply": options.apply = true
        case "--dry-run": options.apply = false
        case "--help", "-h":
            print("""
            Usage: swift run OrzDecodeCacheMaintenance [options]
              --max-bytes N              select oldest files until cache fits N bytes
              --remove-old-fingerprints  select files not produced by the current SDK
              --minimum-age-seconds N    protect recent files (default 300)
              --dry-run                   report selected files without deleting (default)
              --apply                     perform selected deletions
            With no cleanup policy the command only reports cache usage.
            """)
            Foundation.exit(0)
        default: throw CLIError.unknownArgument(arguments[index])
        }
        index += 1
    }
    return options
}

@main
struct DecodeCacheMaintenanceCommand {
    static func main() async throws {
        let cli = try parseOptions()
        let casRoot = Environment.get("CAS_ROOT") ?? "./data/music"
        let summary = try DecodedCacheMaintenanceService(casRoot: casRoot).run(options: .init(
            maximumBytes: cli.maximumBytes,
            removeOldFingerprints: cli.removeOldFingerprints,
            dryRun: !cli.apply,
            minimumAgeSeconds: cli.minimumAgeSeconds
        ))
        print(
            "decode-cache files=\(summary.files) bytes=\(summary.totalBytes) " +
            "selected_files=\(summary.selectedFiles) selected_bytes=\(summary.selectedBytes) " +
            "deleted_files=\(summary.deletedFiles) deleted_bytes=\(summary.deletedBytes) " +
            "busy=\(summary.busyFiles) too_recent=\(summary.tooRecentFiles) " +
            "malformed=\(summary.malformedFiles) failures=\(summary.failures.count) apply=\(cli.apply)"
        )
        for usage in summary.fingerprintUsage {
            print("decode-cache fingerprint=\(usage.fingerprint) files=\(usage.files) bytes=\(usage.bytes)")
        }
        for failure in summary.failures {
            print("decode-cache failure=\(failure)")
        }
        if !summary.failures.isEmpty { Foundation.exit(2) }
    }
}
