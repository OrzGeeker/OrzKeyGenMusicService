import Foundation
import OrzAudioKit

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

let midi = Data([
    0x4d, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 96,
    0x4d, 0x54, 0x72, 0x6b, 0, 0, 0, 15,
    0, 0xc0, 0,
    0, 0x90, 60, 100,
    96, 0x80, 60, 0,
    0, 0xff, 0x2f, 0
])

do {
    let buildInfo = AudioDecoder.buildInfo
    let reportedVersion = buildInfo.data(using: .utf8)
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["version"] as? String
    if ProcessInfo.processInfo.environment["ORZ_AUDIO_CORE_SKIP_VERSION_CHECK"] != "1",
       reportedVersion != DecoderManifest.sdkVersion {
        fail("OrzAudioCore version mismatch: expected \(DecoderManifest.sdkVersion), got \(reportedVersion ?? "unknown")", code: 3)
    }
    let decoder = try AudioDecoder(data: midi, format: "mid")
    let samples = try decoder.render(maxFrames: 4096)
    guard samples.count == 8192, samples.contains(where: { abs($0) > 0.0001 }) else {
        fail("OrzAudioCore smoke decoder rendered invalid PCM", code: 2)
    }
    print("\(buildInfo) frames=\(samples.count / decoder.info.channels)")
} catch {
    fail("OrzAudioCore smoke decoder failed: \(error)", code: 1)
}
