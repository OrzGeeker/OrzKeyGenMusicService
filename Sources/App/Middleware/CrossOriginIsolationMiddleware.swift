import Vapor

/// SharedArrayBuffer requires a cross-origin isolated browsing context.
struct CrossOriginIsolationMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: "Cross-Origin-Opener-Policy", value: "same-origin")
        response.headers.replaceOrAdd(name: "Cross-Origin-Embedder-Policy", value: "require-corp")
        response.headers.replaceOrAdd(name: "Cross-Origin-Resource-Policy", value: "same-origin")
        return response
    }
}
