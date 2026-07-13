import Foundation

/// 模块格式解码器 — libopenmpt / 其他 C 库封装
///
/// 目前为 stub 实现，等 C 库源码 vendored 后接入。
public class ModuleDecoder: @unchecked Sendable {

    public init() {}

    /// 解码模块格式为 PCM
    /// - Parameters:
    ///   - filePath: 文件路径
    ///   - format: 音频格式
    /// - Returns: PCM 数据
    public func decode(filePath: String, format: AudioFormat) throws -> PCMData {
        switch format {
        case .xm, .mod, .it, .s3m, .mo3, .mtm:
            return try decodeWithOpenMPT(filePath: filePath, format: format)
        case .nsf, .spc:
            return try decodeWithGME(filePath: filePath, format: format)
        case .sid:
            return try decodeWithSIDPlay(filePath: filePath)
        case .sc68, .hsc:
            return try decodeWithSC68(filePath: filePath)
        case .ym:
            return try decodeWithSTSound(filePath: filePath)
        case .ahx, .amd, .fc13, .fc14:
            return try decodeWithUADE(filePath: filePath, format: format)
        case .sap:
            return try decodeWithASAP(filePath: filePath)
        case .rad, .d00:
            return try decodeWithAdPlug(filePath: filePath, format: format)
        case .v2m:
            return try decodeWithV2M(filePath: filePath)
        case .bp:
            return try decodeWithFFmpeg(filePath: filePath)
        default:
            throw AudioError.unsupportedFormat("\(format) is not a module format")
        }
    }

    // MARK: - Stub decoders (to be implemented when C libraries are vendored)

    private func decodeWithOpenMPT(filePath: String, format: AudioFormat) throws -> PCMData {
        throw AudioError.decoderNotImplemented("COpenMPT (libopenmpt) not yet integrated")
    }

    private func decodeWithGME(filePath: String, format: AudioFormat) throws -> PCMData {
        throw AudioError.decoderNotImplemented("CGameMusicEmu not yet integrated")
    }

    private func decodeWithSIDPlay(filePath: String) throws -> PCMData {
        throw AudioError.decoderNotImplemented("CSIDPlay not yet integrated")
    }

    private func decodeWithSC68(filePath: String) throws -> PCMData {
        throw AudioError.decoderNotImplemented("CSC68 not yet integrated")
    }

    private func decodeWithSTSound(filePath: String) throws -> PCMData {
        throw AudioError.decoderNotImplemented("CSTSound not yet integrated")
    }

    private func decodeWithUADE(filePath: String, format: AudioFormat) throws -> PCMData {
        throw AudioError.decoderNotImplemented("CUADE not yet integrated")
    }

    private func decodeWithASAP(filePath: String) throws -> PCMData {
        throw AudioError.decoderNotImplemented("CASAP not yet integrated")
    }

    private func decodeWithAdPlug(filePath: String, format: AudioFormat) throws -> PCMData {
        throw AudioError.decoderNotImplemented("CAdPlug not yet integrated")
    }

    private func decodeWithV2M(filePath: String) throws -> PCMData {
        throw AudioError.decoderNotImplemented("CV2M not yet integrated")
    }

    private func decodeWithFFmpeg(filePath: String) throws -> PCMData {
        // For .bp and other unsupported formats, use ffmpeg CLI as last resort
        let decoder = StandardDecoder()
        return try decoder.decode(filePath: filePath, format: .wav)
    }
}
