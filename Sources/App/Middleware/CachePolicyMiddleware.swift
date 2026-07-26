import Vapor

struct CachePolicyMiddleware: AsyncMiddleware {
    private static let cacheableExtensions: Set<String> = [
        "css", "js", "json", "svg", "wasm",
    ]

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        guard response.status.code >= 200, response.status.code < 400 else {
            return response
        }

        let path = request.url.path
        if path == "/" {
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        } else if path == "/api" || path.hasPrefix("/api/") {
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        } else if isVersionedStaticAsset(path: path, query: request.url.query) {
            response.headers.replaceOrAdd(
                name: .cacheControl,
                value: "public, max-age=31536000, immutable"
            )
        } else if isStaticAsset(path: path) {
            response.headers.replaceOrAdd(
                name: .cacheControl,
                value: "public, max-age=3600, must-revalidate"
            )
        }
        if shouldVaryByEncoding(path: path) &&
            !response.headers[.vary].contains(where: { $0.lowercased().contains("accept-encoding") }) {
            response.headers.add(name: .vary, value: "Accept-Encoding")
        }
        return response
    }

    private func isVersionedStaticAsset(path: String, query: String?) -> Bool {
        guard isStaticAsset(path: path) else { return false }
        if query?.split(separator: "&").contains(where: {
            $0.split(separator: "=", maxSplits: 1).first == "v" && $0.contains("=")
        }) == true {
            return true
        }
        return path.hasPrefix("/vendor/") &&
            path.split(separator: "/").last?.contains(where: \.isNumber) == true
    }

    private func isStaticAsset(path: String) -> Bool {
        guard let ext = path.split(separator: ".").last?.lowercased() else {
            return false
        }
        return Self.cacheableExtensions.contains(ext)
    }

    private func shouldVaryByEncoding(path: String) -> Bool {
        if path == "/" || path == "/api" || path.hasPrefix("/api/") {
            return true
        }
        guard let ext = path.split(separator: ".").last?.lowercased() else {
            return false
        }
        return ["css", "js", "json", "svg"].contains(ext)
    }
}
