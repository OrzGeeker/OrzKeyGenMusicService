import Foundation
@testable import App
import Testing

@Suite(.serialized) struct AppVersionTests {

    private let testVersion = "1.2.3"
    private let invalidVersions = ["", "abc", "1.0", "v1.0.0", "1.0.0-beta", "01.0.0", "1.0.0.0"]
    /// 测试用空目录路径，确保不意外找到项目根目录的 VERSION 文件
    private let emptyDir: String = FileManager.default.temporaryDirectory
        .appendingPathComponent("version-empty-\(UUID().uuidString)").path

    // MARK: - 环境变量优先

    @Test func testEnvironmentVariableTakesPriority() async throws {
        let version = AppVersion.resolve(environment: ["APP_VERSION": testVersion])
        #expect(version == testVersion)
    }

    @Test func testEnvironmentVariableOverridesFile() async throws {
        let version = AppVersion.resolve(
            environment: ["APP_VERSION": testVersion],
            currentDirectoryPath: "/nonexistent"
        )
        #expect(version == testVersion)
    }

    @Test func testInvalidEnvironmentVariableFallsBack() async throws {
        let version = AppVersion.resolve(environment: ["APP_VERSION": "v1.0.0"], currentDirectoryPath: emptyDir)
        #expect(version == "development")
    }

    // MARK: - VERSION 文件回退

    @Test func testVersionFileFallback() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("version-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let versionFile = tmpDir.appendingPathComponent("VERSION")
        try? testVersion.write(to: versionFile, atomically: true, encoding: .utf8)

        let version = AppVersion.resolve(
            environment: [:],
            currentDirectoryPath: tmpDir.path
        )
        #expect(version == testVersion)
    }

    @Test func testVersionFileTrimsWhitespace() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("version-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let versionFile = tmpDir.appendingPathComponent("VERSION")
        try? "  \(testVersion)\n".write(to: versionFile, atomically: true, encoding: .utf8)

        let version = AppVersion.resolve(
            environment: [:],
            currentDirectoryPath: tmpDir.path
        )
        #expect(version == testVersion)
    }

    @Test func testInvalidVersionFileFallsBack() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("version-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let versionFile = tmpDir.appendingPathComponent("VERSION")
        try? "v1.0.0".write(to: versionFile, atomically: true, encoding: .utf8)

        let version = AppVersion.resolve(
            environment: [:],
            currentDirectoryPath: tmpDir.path
        )
        #expect(version == "development")
    }

    // MARK: - development 回退

    @Test func testDevelopmentFallbackWhenNoEnvAndNoFile() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("version-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let version = AppVersion.resolve(
            environment: [:],
            currentDirectoryPath: tmpDir.path
        )
        #expect(version == "development")
    }

    @Test func testDevelopmentFallbackWithEmptyEnvVar() async throws {
        let version = AppVersion.resolve(environment: ["APP_VERSION": ""], currentDirectoryPath: emptyDir)
        #expect(version == "development")
    }

    // MARK: - SemVer 格式校验

    @Test func testAllInvalidVersionFormatsReturnDevelopment() async throws {
        for invalid in invalidVersions {
            let version = AppVersion.resolve(environment: ["APP_VERSION": invalid], currentDirectoryPath: emptyDir)
            #expect(version == "development", "Expected 'development' for invalid version: '\(invalid)'")
        }
    }

    @Test func testValidSemVerAccepted() async throws {
        let validVersions = ["0.0.1", "1.0.0", "10.20.30", "999.999.999"]
        for valid in validVersions {
            let version = AppVersion.resolve(environment: ["APP_VERSION": valid], currentDirectoryPath: emptyDir)
            #expect(version == valid, "Expected valid version '\(valid)' to be accepted")
        }
    }
}
