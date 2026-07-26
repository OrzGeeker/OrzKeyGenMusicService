@testable import App
import XCTVapor

final class CachePolicyMiddlewareTests: XCTestCase {
    func testCachePoliciesPreserveExistingResponseHeaders() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        app.middleware.use(CachePolicyMiddleware())
        app.get("audio", "app.js") { _ in
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .eTag, value: "\"asset-etag\"")
            headers.replaceOrAdd(name: .lastModified, value: "Sun, 26 Jul 2026 00:00:00 GMT")
            headers.replaceOrAdd(name: "Cross-Origin-Resource-Policy", value: "same-origin")
            headers.add(name: .vary, value: "Origin")
            return Response(
                status: .ok,
                headers: headers,
                body: .init(string: "console.log('ok')")
            )
        }
        app.get("api", "example") { _ in "[]" }
        app.get { _ in "<html></html>" }

        try app.test(.GET, "/audio/app.js?v=release-1") { response in
            XCTAssertEqual(
                response.headers.first(name: .cacheControl),
                "public, max-age=31536000, immutable"
            )
            XCTAssertEqual(response.headers.first(name: .eTag), "\"asset-etag\"")
            XCTAssertEqual(response.headers.first(name: .lastModified), "Sun, 26 Jul 2026 00:00:00 GMT")
            XCTAssertEqual(response.headers.first(name: "Cross-Origin-Resource-Policy"), "same-origin")
            XCTAssertEqual(Set(response.headers[.vary]), ["Origin", "Accept-Encoding"])
        }
        try app.test(.GET, "/audio/app.js") { response in
            XCTAssertEqual(
                response.headers.first(name: .cacheControl),
                "public, max-age=3600, must-revalidate"
            )
        }
        try app.test(.GET, "/api/example") { response in
            XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
        }
        try app.test(.GET, "/") { response in
            XCTAssertEqual(response.headers.first(name: .cacheControl), "no-cache")
        }
    }
}
