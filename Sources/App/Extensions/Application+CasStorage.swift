import Vapor

private struct CasStorageKey: StorageKey {
    typealias Value = CasStorageService
}

extension Application {
    public var casStorage: CasStorageService {
        get {
            guard let stored = storage[CasStorageKey.self] else {
                fatalError("CasStorageService not configured. Set app.casStorage in configure.swift")
            }
            return stored
        }
        set {
            storage[CasStorageKey.self] = newValue
        }
    }
}
