import Vapor

private struct AdminAPITokenKey: StorageKey {
    typealias Value = AdminAPITokenConfiguration
}

private struct AdminAPITokenConfiguration {
    let token: String?
}

extension Application {
    /// Token required by administrative, mutating library endpoints.
    ///
    /// A missing or blank value deliberately leaves those endpoints disabled.
    public var adminAPIToken: String? {
        get {
            if let configured = storage[AdminAPITokenKey.self] {
                return configured.token
            }

            let environmentToken = Environment.get("ADMIN_API_TOKEN")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return environmentToken?.isEmpty == false ? environmentToken : nil
        }
        set {
            let normalized = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            storage[AdminAPITokenKey.self] = AdminAPITokenConfiguration(
                token: normalized?.isEmpty == false ? normalized : nil
            )
        }
    }
}
