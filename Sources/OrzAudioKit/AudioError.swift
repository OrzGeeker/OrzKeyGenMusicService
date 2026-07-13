import Foundation

/// 音频解码错误类型
public enum AudioError: LocalizedError, Sendable {
    case decoderNotImplemented(String)
    case decodeFailed(String)
    case unsupportedFormat(String)
    case fileNotFound(String)
    case invalidPCMData(String)

    public var errorDescription: String? {
        switch self {
        case .decoderNotImplemented(let msg): return "Decoder not implemented: \(msg)"
        case .decodeFailed(let msg):          return "Decode failed: \(msg)"
        case .unsupportedFormat(let msg):     return "Unsupported format: \(msg)"
        case .fileNotFound(let msg):          return "File not found: \(msg)"
        case .invalidPCMData(let msg):        return "Invalid PCM data: \(msg)"
        }
    }
}
