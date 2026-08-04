import Foundation
import VaporTesting
import Testing
@testable import App

@Suite(.serialized) struct PlaybackDiagnosticsControllerTests {
    private func withDiagnosticsEnvironment<T>(
        _ enabled: Bool,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let name = "PLAYBACK_DIAGNOSTICS_ENABLED"
        let previous = ProcessInfo.processInfo.environment[name]
        setenv(name, enabled ? "true" : "false", 1)
        defer {
            if let previous {
                setenv(name, previous, 1)
            } else {
                unsetenv(name)
            }
        }
        return try await body()
    }

    @Test func testEndpointIsUnavailableWhenDiagnosticsAreDisabled() async throws {
        try await withDiagnosticsEnvironment(false) {
            let app = try await Application.make(.testing)
            defer { scheduleShutdown(app) }
            try app.register(collection: PlaybackDiagnosticsController())

            try await app.test(.POST, "/api/diagnostics/playback", beforeRequest: { request in
                try request.content.encode([
                    "strategy": "directFile",
                    "format": "ogg",
                    "firstFrameMs": "12",
                    "clickToPlayingMs": "12",
                    "underruns": "0",
                    "fallbackUsed": "false",
                ])
            }, afterResponse: { response in
                #expect(response.status == .notFound)
            })
        }
    }

    @Test func testEnabledEndpointAcceptsBoundedAnonymousMetrics() async throws {
        try await withDiagnosticsEnvironment(true) {
            let app = try await Application.make(.testing)
            defer { scheduleShutdown(app) }
            try app.register(collection: PlaybackDiagnosticsController())
            let payload = PlaybackDiagnosticsController.Payload(
                strategy: "wasmDecode",
                format: "xm",
                resourceFetchMs: 20,
                wasmReadyMs: 1,
                workerReadyMs: 10,
                firstFrameMs: 35,
                clickToPlayingMs: 35,
                underruns: 0,
                fallbackUsed: false
            )

            try await app.test(.POST, "/api/diagnostics/playback", beforeRequest: { request in
                try request.content.encode(payload)
            }, afterResponse: { response in
                #expect(response.status == .noContent)
            })
        }
    }

    @Test func testEndpointRejectsUnboundedOrIdentifyingFormatValues() async throws {
        try await withDiagnosticsEnvironment(true) {
            let app = try await Application.make(.testing)
            defer { scheduleShutdown(app) }
            try app.register(collection: PlaybackDiagnosticsController())
            let payload = PlaybackDiagnosticsController.Payload(
                strategy: "serverDecode",
                format: "/Users/private/song.wav",
                resourceFetchMs: nil,
                wasmReadyMs: nil,
                workerReadyMs: nil,
                firstFrameMs: 1_000_000,
                clickToPlayingMs: 1_000_000,
                underruns: 0,
                fallbackUsed: false
            )

            try await app.test(.POST, "/api/diagnostics/playback", beforeRequest: { request in
                try request.content.encode(payload)
            }, afterResponse: { response in
                #expect(response.status == .badRequest)
            })
        }
    }
}
