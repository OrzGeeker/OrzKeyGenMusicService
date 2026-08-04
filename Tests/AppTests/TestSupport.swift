import Foundation
import VaporTesting

/// Schedules `app.asyncShutdown()` to run on a detached `Task`.
///
/// swift-testing test methods are async, so a `defer` block cannot `await`.
/// Vapor's sync `shutdown()` is `@available(*, noasync)` and blocks the
/// cooperative thread pool when called from an async test, which can deadlock
/// parallel test runs. Scheduling the true async shutdown on a `Task` keeps
/// teardown fully async without occupying a pool thread.
func scheduleShutdown(_ app: Application) {
    Task { try? await app.asyncShutdown() }
}
