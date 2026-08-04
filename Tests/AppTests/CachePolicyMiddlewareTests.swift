import Foundation
@testable import App
import VaporTesting
import Testing

@Suite(.serialized) struct CachePolicyMiddlewareTests {
    @Test func testCachePoliciesPreserveExistingResponseHeaders() async throws {
        let app = try await Application.make(.testing)
        defer { scheduleShutdown(app) }
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

        try await app.test(.GET, "/audio/app.js?v=release-1") { response in
            #expect(response.headers.first(name: .cacheControl) == "public, max-age=31536000, immutable")
            #expect(response.headers.first(name: .eTag) == "\"asset-etag\"")
            #expect(response.headers.first(name: .lastModified) == "Sun, 26 Jul 2026 00:00:00 GMT")
            #expect(response.headers.first(name: "Cross-Origin-Resource-Policy") == "same-origin")
            #expect(Set(response.headers[.vary]) == ["Origin", "Accept-Encoding"])
        }
        try await app.test(.GET, "/audio/app.js") { response in
            #expect(response.headers.first(name: .cacheControl) == "public, max-age=3600, must-revalidate")
        }
        try await app.test(.GET, "/api/example") { response in
            #expect(response.headers.first(name: .cacheControl) == "no-store")
        }
        try await app.test(.GET, "/") { response in
            #expect(response.headers.first(name: .cacheControl) == "no-cache")
        }
    }
}
