import Foundation

/// Shared duration probe used by scanning and maintenance workflows.
public enum AudioDurationProbe {
    public static func duration(
        filePath: String,
        format: String,
        timeout: TimeInterval = 5
    ) async -> Double? {
        if CDecoderBridge.canDecode(format: format),
           let value = try? CDecoderBridge.duration(filePath: filePath, format: format),
           value.isFinite, value > 0 {
            return value
        }

        do {
            let output = try await ProcessRunner.execute(arguments: [
                "ffprobe", "-v", "quiet",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                filePath,
            ], timeout: timeout)
            guard let value = Double(output), value.isFinite, value > 0 else { return nil }
            return value
        } catch {
            return nil
        }
    }
}
