import XCTVapor
@testable import App

final class PlaybackDiagnosticsControllerTests: XCTestCase {
    private func withDiagnosticsEnvironment<T>(
        _ enabled: Bool,
        _ body: () throws -> T
    ) rethrows -> T {
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
        return try body()
    }

    func testEndpointIsUnavailableWhenDiagnosticsAreDisabled() throws {
        try withDiagnosticsEnvironment(false) {
            let app = Application(.testing)
            defer { app.shutdown() }
            try app.register(collection: PlaybackDiagnosticsController())

            try app.test(.POST, "/api/diagnostics/playback", beforeRequest: { request in
                try request.content.encode([
                    "strategy": "directFile",
                    "format": "ogg",
                    "firstFrameMs": "12",
                    "clickToPlayingMs": "12",
                    "underruns": "0",
                    "fallbackUsed": "false",
                ])
            }, afterResponse: { response in
                XCTAssertEqual(response.status, .notFound)
            })
        }
    }

    func testEnabledEndpointAcceptsBoundedAnonymousMetrics() throws {
        try withDiagnosticsEnvironment(true) {
            let app = Application(.testing)
            defer { app.shutdown() }
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

            try app.test(.POST, "/api/diagnostics/playback", beforeRequest: { request in
                try request.content.encode(payload)
            }, afterResponse: { response in
                XCTAssertEqual(response.status, .noContent)
            })
        }
    }

    func testEndpointRejectsUnboundedOrIdentifyingFormatValues() throws {
        try withDiagnosticsEnvironment(true) {
            let app = Application(.testing)
            defer { app.shutdown() }
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

            try app.test(.POST, "/api/diagnostics/playback", beforeRequest: { request in
                try request.content.encode(payload)
            }, afterResponse: { response in
                XCTAssertEqual(response.status, .badRequest)
            })
        }
    }
}
