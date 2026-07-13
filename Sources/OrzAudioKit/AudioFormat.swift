import Foundation

/// 音频格式枚举，包含所有支持的格式及其解码策略
public enum AudioFormat: String, CaseIterable, Codable, Sendable {
    // 模块格式 — libopenmpt 解码
    case xm, mod, it, s3m, mo3, mtm
    // 标准格式 — 直接流式输出 / AVFoundation
    case mp3, ogg, wav, flac, mid, m4a, aac
    // 游戏音频 — Game Music Emu
    case nsf, spc
    // Commodore 64 — libsidplay2
    case sid
    // Atari ST — libsc68 / ST-Sound
    case sc68, hsc, ym
    // Amiga — uADE
    case ahx, amd, fc13, fc14
    // Atari POKEY — ASAP
    case sap
    // AdLib OPL2/3 — AdPlug
    case rad, d00
    // Farbrausch V2 — v2m-player
    case v2m
    // 自定义私有格式
    case bp

    /// 浏览器播放策略
    public enum PlayStrategy: String, Codable, CaseIterable, Sendable {
        /// 浏览器原生支持，直接返回原始文件
        case directFile
        /// 通过 WASM 解码
        case wasmDecode
        /// 服务端解码为 WAV
        case serverDecode
    }

    /// 该格式对应的播放策略
    public var playStrategy: PlayStrategy {
        switch self {
        case .mp3, .ogg, .wav, .flac, .mid, .m4a, .aac:
            return .directFile
        case .xm, .mod, .it, .s3m, .mo3, .mtm:
            return .wasmDecode
        case .v2m, .sc68, .hsc, .sid, .nsf, .spc:
            return .wasmDecode
        case .ahx, .amd, .fc13, .fc14, .sap, .ym, .rad, .d00:
            return .wasmDecode
        case .bp:
            return .serverDecode
        }
    }

    /// MIME 类型
    public var mimeType: String {
        switch self {
        case .mp3:  return "audio/mpeg"
        case .ogg:  return "audio/ogg"
        case .wav:  return "audio/wav"
        case .flac: return "audio/flac"
        case .mid:  return "audio/midi"
        case .m4a, .aac: return "audio/mp4"
        case .xm, .mod, .it, .s3m, .mo3, .mtm: return "audio/x-mod"
        default:    return "application/octet-stream"
        }
    }

    /// 从文件扩展名创建
    public static func from(fileExtension: String) -> AudioFormat? {
        AudioFormat(rawValue: fileExtension.lowercased())
    }
}
