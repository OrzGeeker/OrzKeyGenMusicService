import Vapor

private struct ScanRootKey: StorageKey {
    typealias Value = ScanRootConfiguration
}

private struct ScanRootConfiguration {
    let path: String?
}

extension Application {
    /// Server-side music library root used by the administrative scan endpoint.
    ///
    /// The HTTP client cannot override this path.
    public var scanRoot: String? {
        get {
            if let configured = storage[ScanRootKey.self] {
                return configured.path
            }

            let environmentPath = Environment.get("SCAN_ROOT")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return environmentPath?.isEmpty == false ? environmentPath : nil
        }
        set {
            let normalized = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            storage[ScanRootKey.self] = ScanRootConfiguration(
                path: normalized?.isEmpty == false ? normalized : nil
            )
        }
    }
}
