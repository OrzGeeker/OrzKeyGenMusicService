import Vapor

struct PlaybackDiagnosticsController: RouteCollection {
    struct Payload: Content {
        let strategy: String
        let format: String
        let resourceFetchMs: Double?
        let wasmReadyMs: Double?
        let workerReadyMs: Double?
        let firstFrameMs: Double
        let clickToPlayingMs: Double
        let underruns: Int
        let fallbackUsed: Bool
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("api", "diagnostics").post("playback", use: record)
    }

    @Sendable
    func record(req: Request) throws -> HTTPStatus {
        guard Environment.get("PLAYBACK_DIAGNOSTICS_ENABLED") == "true" else {
            throw Abort(.notFound)
        }
        let payload = try req.content.decode(Payload.self)
        guard ["directFile", "wasmDecode", "serverDecode"].contains(payload.strategy),
              !payload.format.isEmpty, payload.format.count <= 16,
              payload.format.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              valid(payload.resourceFetchMs),
              valid(payload.wasmReadyMs),
              valid(payload.workerReadyMs),
              valid(payload.firstFrameMs),
              valid(payload.clickToPlayingMs),
              payload.underruns >= 0, payload.underruns <= 1_000_000 else {
            throw Abort(.badRequest, reason: "Invalid playback diagnostic")
        }
        var metadata: Logger.Metadata = [:]
        metadata["strategy"] = "\(payload.strategy)"
        metadata["format"] = "\(payload.format)"
        metadata["resource_fetch_ms"] = "\(metric(payload.resourceFetchMs))"
        metadata["wasm_ready_ms"] = "\(metric(payload.wasmReadyMs))"
        metadata["worker_ready_ms"] = "\(metric(payload.workerReadyMs))"
        metadata["first_frame_ms"] = "\(payload.firstFrameMs)"
        metadata["click_to_playing_ms"] = "\(payload.clickToPlayingMs)"
        metadata["underruns"] = "\(payload.underruns)"
        metadata["fallback_used"] = "\(payload.fallbackUsed)"
        req.logger.info("playback_first_frame", metadata: metadata)
        return .noContent
    }

    private func valid(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0 && value <= 600_000
    }

    private func metric(_ value: Double?) -> String {
        value.map { String($0) } ?? "null"
    }
}
