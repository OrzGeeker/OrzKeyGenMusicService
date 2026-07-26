import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum DecodedCacheFileLeaseError: Error {
    case cannotOpenLock
    case busy
}

/// Cross-process advisory lease for one finalized decoded WAV.
///
/// Web streams hold a shared lease until Vapor calls `onCompleted`; cleanup
/// must obtain an exclusive non-blocking lease before deleting the WAV.
public final class DecodedCacheFileLease: @unchecked Sendable {
    private let descriptor: Int32
    private let mutex = NSLock()
    private var released = false

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public static func acquireShared(for cachePath: String) throws -> DecodedCacheFileLease {
        try acquire(for: cachePath, operation: LOCK_SH)
    }

    public static func tryAcquireExclusive(for cachePath: String) throws -> DecodedCacheFileLease {
        try acquire(for: cachePath, operation: LOCK_EX | LOCK_NB)
    }

    private static func acquire(for cachePath: String, operation: Int32) throws -> DecodedCacheFileLease {
        let cacheURL = URL(fileURLWithPath: cachePath)
        let lockDirectory = cacheURL.deletingLastPathComponent().appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let lockURL = lockDirectory.appendingPathComponent(cacheURL.lastPathComponent + ".lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DecodedCacheFileLeaseError.cannotOpenLock }
        guard flock(descriptor, operation) == 0 else {
            close(descriptor)
            if errno == EWOULDBLOCK { throw DecodedCacheFileLeaseError.busy }
            throw DecodedCacheFileLeaseError.cannotOpenLock
        }
        return DecodedCacheFileLease(descriptor: descriptor)
    }

    public func release() {
        mutex.lock()
        guard !released else {
            mutex.unlock()
            return
        }
        released = true
        mutex.unlock()
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit {
        release()
    }
}
