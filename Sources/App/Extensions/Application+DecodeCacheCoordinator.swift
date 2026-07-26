import Vapor

private struct DecodeCacheCoordinatorKey: StorageKey {
    typealias Value = DecodeCacheCoordinator
}

extension Application {
    public var decodeCacheCoordinator: DecodeCacheCoordinator {
        if let stored = storage[DecodeCacheCoordinatorKey.self] {
            return stored
        }
        let configured = Environment.get("SERVER_DECODE_CONCURRENCY").flatMap(Int.init(_:))
        let limit = configured.map { max(1, min($0, 32)) } ?? 1
        let coordinator = DecodeCacheCoordinator(concurrencyLimit: limit)
        storage[DecodeCacheCoordinatorKey.self] = coordinator
        return coordinator
    }

    public func initializeDecodeCacheCoordinator() {
        _ = decodeCacheCoordinator
    }
}
