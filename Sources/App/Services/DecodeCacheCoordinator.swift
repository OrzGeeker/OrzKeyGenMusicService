import Foundation

/// Identifies one immutable decoded WAV artifact.
public struct DecodeCacheKey: Hashable, Sendable {
    public let sha256: String
    public let decoderFingerprint: String
    public let format: String
    public let sampleRate: String
    public let channels: String
    public let subsong: Int

    public init(sha256: String, decoderFingerprint: String, format: String, sampleRate: String, channels: String, subsong: Int) {
        self.sha256 = sha256
        self.decoderFingerprint = decoderFingerprint
        self.format = format
        self.sampleRate = sampleRate
        self.channels = channels
        self.subsong = subsong
    }
}

/// Coalesces concurrent cache misses for the same decoded WAV artifact.
///
/// The shared task is not a child of any request, so cancelling one HTTP
/// waiter does not cancel work still needed by other waiters.
public actor DecodeCacheCoordinator {
    public struct Result: Sendable {
        public let path: String
        public let queueMilliseconds: Double
        public let decodeMilliseconds: Double
    }

    private struct Flight {
        let id: UUID
        let task: Task<Result, Error>
    }

    private var flights: [DecodeCacheKey: Flight] = [:]
    private let concurrencyLimit: Int
    private var activeDecodes = 0
    private var permitWaiters: [CheckedContinuation<Void, Never>] = []

    public init(concurrencyLimit: Int = 1) {
        self.concurrencyLimit = max(1, concurrencyLimit)
    }

    public func run(
        key: DecodeCacheKey,
        operation: @escaping @Sendable () async throws -> String,
        onFailure: (@Sendable (_ queueMilliseconds: Double, _ decodeMilliseconds: Double, _ error: any Error) -> Void)? = nil
    ) async throws -> Result {
        if let flight = flights[key] {
            return try await flight.task.value
        }

        let flight = Flight(id: UUID(), task: Task {
            let queuedAt = ContinuousClock.now
            await self.acquirePermit()
            let startedAt = ContinuousClock.now
            do {
                let path = try await operation()
                let finishedAt = ContinuousClock.now
                self.releasePermit()
                return Result(
                    path: path,
                    queueMilliseconds: Self.milliseconds(queuedAt.duration(to: startedAt)),
                    decodeMilliseconds: Self.milliseconds(startedAt.duration(to: finishedAt))
                )
            } catch {
                let failedAt = ContinuousClock.now
                onFailure?(
                    Self.milliseconds(queuedAt.duration(to: startedAt)),
                    Self.milliseconds(startedAt.duration(to: failedAt)),
                    error
                )
                self.releasePermit()
                throw error
            }
        })
        flights[key] = flight

        do {
            let value = try await flight.task.value
            removeFlight(key: key, id: flight.id)
            return value
        } catch {
            removeFlight(key: key, id: flight.id)
            throw error
        }
    }

    public func activeFlightCount() -> Int {
        flights.count
    }

    public func diagnostics() -> (limit: Int, active: Int, queued: Int) {
        (concurrencyLimit, activeDecodes, permitWaiters.count)
    }

    private func acquirePermit() async {
        if activeDecodes < concurrencyLimit {
            activeDecodes += 1
            return
        }
        await withCheckedContinuation { continuation in
            permitWaiters.append(continuation)
        }
    }

    private func releasePermit() {
        if !permitWaiters.isEmpty {
            permitWaiters.removeFirst().resume()
        } else {
            activeDecodes -= 1
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func removeFlight(key: DecodeCacheKey, id: UUID) {
        guard flights[key]?.id == id else { return }
        flights.removeValue(forKey: key)
    }
}
