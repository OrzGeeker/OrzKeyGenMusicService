import Foundation

/// 应用版本单一来源。
///
/// 按以下固定优先级解析版本值：
/// 1. `APP_VERSION` 环境变量
/// 2. 当前工作目录下的 `VERSION` 文件
/// 3. 回退到 `"development"`
///
/// 环境变量或 VERSION 文件内容必须是合法的 SemVer（`X.Y.Z`），否则视为不存在。
struct AppVersion {

    /// 当前应用版本字符串。
    static var current: String {
        resolve()
    }

    /// 解析版本字符串，支持注入依赖以便测试。
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> String {
        // Priority 1: 环境变量
        if let envVersion = environment["APP_VERSION"], isValidVersion(envVersion) {
            return envVersion
        }

        // Priority 2: 当前工作目录下的 VERSION 文件
        let versionPath = (currentDirectoryPath as NSString).appendingPathComponent("VERSION")
        if let fileContent = try? String(contentsOfFile: versionPath, encoding: .utf8) {
            let trimmed = fileContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && isValidVersion(trimmed) {
                return trimmed
            }
        }

        // Fallback
        return "development"
    }

    /// 校验是否为合法的 SemVer 格式 `X.Y.Z`，禁止前导零
    private static func isValidVersion(_ version: String) -> Bool {
        let pattern = #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$"#
        return version.range(of: pattern, options: .regularExpression) != nil
    }
}
