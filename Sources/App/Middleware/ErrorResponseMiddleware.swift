import Vapor

/// 统一错误响应格式
///
/// 将所有 Abort 错误转换为标准 JSON 响应：
/// ```json
/// { "error": "notFound", "reason": "Song not found", "code": 404 }
/// ```
struct ErrorResponseMiddleware: Middleware {

    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        next.respond(to: request).flatMapErrorThrowing { error in
            switch error {
            case let scanError as ScanAPIError:
                return try self.jsonResponse(
                    status: scanError.status,
                    error: scanError.errorCode,
                    reason: scanError.reason
                )

            case let abort as Abort:
                let reason = abort.reason.isEmpty ? statusReason(abort.status) : abort.reason
                return try self.jsonResponse(
                    status: abort.status,
                    error: self.errorCode(for: abort.status, request: request),
                    reason: reason
                )

            default:
                // Log unexpected errors
                request.logger.error("Unhandled error: \(error.localizedDescription)")
                return try self.jsonResponse(
                    status: .internalServerError,
                    error: "internalServerError",
                    reason: "An unexpected error occurred"
                )
            }
        }
    }

    // MARK: - Private

    private func jsonResponse(status: HTTPStatus, error: String, reason: String) throws -> Response {
        let body: [String: Any] = [
            "error": error,
            "reason": reason,
            "code": status.code
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = Response(status: status, body: .init(data: data))
        response.headers.replaceOrAdd(name: .contentType, value: "application/json")
        return response
    }

    private func errorCode(for status: HTTPStatus, request: Request) -> String {
        switch status {
        case .notFound: return "notFound"
        case .badRequest: return "badRequest"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .conflict: return "conflict"
        case .tooManyRequests: return "rateLimited"
        case .internalServerError: return "internalServerError"
        case .notImplemented: return "notImplemented"
        case .payloadTooLarge:
            // The upload route has a user-visible file-size contract. Preserve
            // the generic code for every other endpoint.
            return request.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "api/upload"
                ? "upload_too_large"
                : "payloadTooLarge"
        default: return "httpError"
        }
    }

    private func statusReason(_ status: HTTPStatus) -> String {
        HTTPResponseStatus(statusCode: Int(status.code)).reasonPhrase
    }
}
