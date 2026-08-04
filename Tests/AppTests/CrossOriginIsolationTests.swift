import Foundation
import VaporTesting
import Testing
@testable import App

@Suite(.serialized) struct CrossOriginIsolationTests {
    @Test func testMiddlewareAddsSharedArrayBufferHeaders() async throws {
        let app = try await Application.make(.testing)
        defer { scheduleShutdown(app) }
        app.middleware.use(CrossOriginIsolationMiddleware())
        app.get("headers") { _ in "ok" }

        try await app.test(.GET, "headers") { response in
            #expect(response.headers.first(name: "Cross-Origin-Opener-Policy") == "same-origin")
            #expect(response.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp")
            #expect(response.headers.first(name: "Cross-Origin-Resource-Policy") == "same-origin")
        }
    }
}
