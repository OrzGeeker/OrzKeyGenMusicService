import XCTest
@testable import App

final class DecodeCacheCoordinatorTests: XCTestCase {
    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    private struct ExpectedFailure: Error {}

    private static func key(subsong: Int = 0) -> DecodeCacheKey {
        DecodeCacheKey(
            sha256: "abc",
            decoderFingerprint: "sdk-v1",
            format: "sc68",
            sampleRate: "native",
            channels: "native",
            subsong: subsong
        )
    }

    func testConcurrentSameKeyRunsOperationOnce() async throws {
        let coordinator = DecodeCacheCoordinator()
        let counter = Counter()
        let sharedKey = Self.key()

        let values = try await withThrowingTaskGroup(of: DecodeCacheCoordinator.Result.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await coordinator.run(key: sharedKey) {
                        await counter.increment()
                        try await Task.sleep(for: .milliseconds(50))
                        return "/cache/result.wav"
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(Set(values.map(\.path)), ["/cache/result.wav"])
        let operationCount = await counter.value
        let activeFlights = await coordinator.activeFlightCount()
        XCTAssertEqual(operationCount, 1)
        XCTAssertEqual(activeFlights, 0)
    }

    func testDifferentSubsongKeysRunIndependently() async throws {
        let coordinator = DecodeCacheCoordinator()
        let counter = Counter()
        let firstKey = Self.key(subsong: 0)
        let secondKey = Self.key(subsong: 1)

        async let first = coordinator.run(key: firstKey) {
            await counter.increment()
            return "zero"
        }
        async let second = coordinator.run(key: secondKey) {
            await counter.increment()
            return "one"
        }

        let result = try await [first, second]
        let operationCount = await counter.value
        XCTAssertEqual(Set(result.map(\.path)), ["zero", "one"])
        XCTAssertEqual(operationCount, 2)
    }

    func testFailureIsSharedAndNextRequestCanRetry() async throws {
        let coordinator = DecodeCacheCoordinator()
        let counter = Counter()
        let sharedKey = Self.key()

        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do {
                        _ = try await coordinator.run(key: sharedKey) {
                            await counter.increment()
                            try await Task.sleep(for: .milliseconds(30))
                            throw ExpectedFailure()
                        }
                        return false
                    } catch is ExpectedFailure {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertTrue(failures.allSatisfy { $0 })
        let failedOperationCount = await counter.value
        XCTAssertEqual(failedOperationCount, 1)
        let retried = try await coordinator.run(key: sharedKey) {
            await counter.increment()
            return "retried"
        }
        let retriedOperationCount = await counter.value
        XCTAssertEqual(retried.path, "retried")
        XCTAssertEqual(retriedOperationCount, 2)
    }

    func testCancellingOneWaiterDoesNotCancelSharedWork() async throws {
        let coordinator = DecodeCacheCoordinator()
        let counter = Counter()
        let sharedKey = Self.key()

        let first = Task {
            try await coordinator.run(key: sharedKey) {
                await counter.increment()
                try await Task.sleep(for: .milliseconds(80))
                return "complete"
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        let second = Task { try await coordinator.run(key: sharedKey) { "unexpected" } }
        first.cancel()

        let secondValue = try await second.value
        let operationCount = await counter.value
        XCTAssertEqual(secondValue.path, "complete")
        XCTAssertEqual(operationCount, 1)
    }

    func testGlobalLimitCapsDifferentKeys() async throws {
        actor Gauge {
            var active = 0
            var maximum = 0
            func entered() {
                active += 1
                maximum = max(maximum, active)
            }
            func exited() { active -= 1 }
        }

        let coordinator = DecodeCacheCoordinator(concurrencyLimit: 2)
        let gauge = Gauge()
        let keys = (0..<12).map { Self.key(subsong: $0) }

        try await withThrowingTaskGroup(of: DecodeCacheCoordinator.Result.self) { group in
            for key in keys {
                group.addTask {
                    try await coordinator.run(key: key) {
                        await gauge.entered()
                        try await Task.sleep(for: .milliseconds(20))
                        await gauge.exited()
                        return "\(key.subsong)"
                    }
                }
            }
            for try await _ in group {}
        }

        let maximum = await gauge.maximum
        let diagnostics = await coordinator.diagnostics()
        XCTAssertEqual(maximum, 2)
        XCTAssertEqual(diagnostics.limit, 2)
        XCTAssertEqual(diagnostics.active, 0)
        XCTAssertEqual(diagnostics.queued, 0)
    }

    func testCancelledQueuedWaiterDoesNotLeakPermit() async throws {
        let coordinator = DecodeCacheCoordinator(concurrencyLimit: 1)
        let firstKey = Self.key(subsong: 100)
        let queuedKey = Self.key(subsong: 101)

        let first = Task {
            try await coordinator.run(key: firstKey) {
                try await Task.sleep(for: .milliseconds(60))
                return "first"
            }
        }
        try await Task.sleep(for: .milliseconds(5))
        let queued = Task {
            try await coordinator.run(key: queuedKey) {
                try await Task.sleep(for: .milliseconds(10))
                return "queued"
            }
        }
        try await Task.sleep(for: .milliseconds(5))
        queued.cancel()

        _ = try await first.value
        _ = try await queued.value
        let diagnostics = await coordinator.diagnostics()
        XCTAssertEqual(diagnostics.active, 0)
        XCTAssertEqual(diagnostics.queued, 0)
    }
}
