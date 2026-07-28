import Vapor

/// Guards administrative endpoints behind the deployment-provided bearer token.
///
/// The guard is intentionally fail-closed: endpoints remain unavailable until
/// `ADMIN_API_TOKEN` is configured.
struct AdminAPITokenMiddleware: Middleware {
    private struct ErrorBody: Content {
        let error: String
        let reason: String
        let code: Int
    }

    private let token: String?

    init(token: String?) {
        self.token = token
    }

    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        guard let token else {
            return request.eventLoop.makeSucceededFuture(errorResponse(
                status: .serviceUnavailable,
                error: "admin_api_disabled",
                reason: "Administrative API is disabled"
            ))
        }

        guard request.headers.first(name: .authorization) == "Bearer \(token)" else {
            return request.eventLoop.makeSucceededFuture(errorResponse(
                status: .unauthorized,
                error: "unauthorized",
                reason: "Missing or invalid bearer token"
            ))
        }

        return next.respond(to: request)
    }

    private func errorResponse(status: HTTPStatus, error: String, reason: String) -> Response {
        let response = Response(status: status)
        try? response.content.encode(
            ErrorBody(error: error, reason: reason, code: Int(status.code)),
            as: .json
        )
        return response
    }
}
