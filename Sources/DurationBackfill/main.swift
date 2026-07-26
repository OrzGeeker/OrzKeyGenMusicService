import App
import Foundation
import Vapor

private struct CLIOptions {
    var batchSize = 50
    var concurrency = 2
    var limit: Int?
    var dryRun = false
}

private enum CLIError: LocalizedError {
    case missingValue(String)
    case invalidValue(String)
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let name): "Missing value for \(name)"
        case .invalidValue(let name): "Invalid value for \(name)"
        case .unknownArgument(let name): "Unknown argument: \(name)"
        }
    }
}

private func parseOptions() throws -> CLIOptions {
    var options = CLIOptions()
    var index = 1
    let arguments = CommandLine.arguments

    func positiveInt(_ name: String) throws -> Int {
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(name) }
        guard let value = Int(arguments[index]), value > 0 else { throw CLIError.invalidValue(name) }
        return value
    }

    while index < arguments.count {
        switch arguments[index] {
        case "--batch-size": options.batchSize = try positiveInt("--batch-size")
        case "--concurrency": options.concurrency = try positiveInt("--concurrency")
        case "--limit": options.limit = try positiveInt("--limit")
        case "--dry-run": options.dryRun = true
        case "--help", "-h":
            print("""
            Usage: swift run OrzDurationBackfill [options]
              --batch-size N   database batch size (default 50)
              --concurrency N  concurrent probes (default 2)
              --limit N        maximum rows selected
              --dry-run        count selected rows without probing or writing
            """)
            Foundation.exit(0)
        default: throw CLIError.unknownArgument(arguments[index])
        }
        index += 1
    }
    return options
}

@main
struct DurationBackfillCommand {
    static func main() async throws {
        let cli = try parseOptions()
        let app = try await Application.make(.production)
        do {
            try configure(app)

            let summary = try await DurationBackfillService(
                database: app.db,
                cas: app.casStorage
            ).run(options: .init(
                batchSize: cli.batchSize,
                concurrency: cli.concurrency,
                limit: cli.limit,
                dryRun: cli.dryRun
            ))

            print(
                "duration-backfill selected=\(summary.selected) updated=\(summary.updated) " +
                "missing_files=\(summary.missingFiles) probe_failures=\(summary.probeFailures) " +
                "dry_run=\(cli.dryRun)"
            )
            for failure in summary.failures {
                print(
                    "duration-backfill failure id=\(failure.id?.uuidString ?? "unknown") " +
                    "format=\(failure.format) reason=\(failure.reason)"
                )
            }
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
}
