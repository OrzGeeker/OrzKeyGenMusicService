import XCTVapor
@testable import App

final class CrossOriginIsolationTests: XCTestCase {
    func testMiddlewareAddsSharedArrayBufferHeaders() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        app.middleware.use(CrossOriginIsolationMiddleware())
        app.get("headers") { _ in "ok" }

        try app.test(.GET, "headers") { response in
            XCTAssertEqual(response.headers.first(name: "Cross-Origin-Opener-Policy"), "same-origin")
            XCTAssertEqual(response.headers.first(name: "Cross-Origin-Embedder-Policy"), "require-corp")
            XCTAssertEqual(response.headers.first(name: "Cross-Origin-Resource-Policy"), "same-origin")
        }
    }
}
