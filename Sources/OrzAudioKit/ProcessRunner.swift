import Foundation

/// 异步进程执行结果
public struct ProcessResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let terminationStatus: Int32

    public var stdoutString: String? {
        String(data: stdout, encoding: .utf8)
    }

    public var stderrString: String? {
        String(data: stderr, encoding: .utf8)
    }
}

/// 异步进程执行器
///
/// 将 Foundation.Process 包装为 async/await 模式，
/// 避免 waitUntilExit() 阻塞 Swift Concurrency 线程池。
public enum ProcessRunner {

    /// 异步运行一个进程，返回 stdout/stderr
    /// - Parameter process: 已配置好的 Process 实例
    /// - Returns: ProcessResult（stdout、stderr、退出码）
    public static func run(_ process: Process) async throws -> ProcessResult {
        // Process 本身不是 Sendable 的，所以在线程之间传递时要小心。
        // 关键是 terminationHandler 会在任意后台线程回调，但我们用 continuation 接回来。
        return try await withCheckedThrowingContinuation { continuation in
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let result = ProcessResult(
                    stdout: stdout,
                    stderr: stderr,
                    terminationStatus: proc.terminationStatus
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// 异步运行一个命令行工具并返回 stdout 字符串
    /// - Parameters:
    ///   - executable: 可执行文件路径（默认 /usr/bin/env）
    ///   - arguments: 参数列表
    ///   - environment: 可选的环境变量
    /// - Returns: stdout 字符串（去除首尾空白）
    public static func execute(
        _ executable: String = "/usr/bin/env",
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let env = environment {
            process.environment = env
        }

        let result = try await run(process)
        return (result.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
