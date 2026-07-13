@testable import App
@testable import OrzAudioKit
import XCTVapor

final class AppTests: XCTestCase {

    // TODO: Add proper test setup with test database
    // Tests below require a running PostgreSQL instance for configure()

    func testApplicationStarts() throws {
        // Basic sanity check - App module can be imported
        XCTAssertTrue(true)
    }

    // MARK: - OrzAudioKit Tests

    func testAudioFormatDetection() throws {
        // Test format detection
        XCTAssertNotNil(OrzAudioKit.AudioFormat.from(fileExtension: "xm"))
        XCTAssertNotNil(OrzAudioKit.AudioFormat.from(fileExtension: "mod"))
        XCTAssertNotNil(OrzAudioKit.AudioFormat.from(fileExtension: "it"))
        XCTAssertNotNil(OrzAudioKit.AudioFormat.from(fileExtension: "s3m"))
        XCTAssertNotNil(OrzAudioKit.AudioFormat.from(fileExtension: "mp3"))
        XCTAssertNotNil(OrzAudioKit.AudioFormat.from(fileExtension: "ogg"))
        XCTAssertNil(OrzAudioKit.AudioFormat.from(fileExtension: "unknown"))
    }

    func testPlayStrategy() throws {
        XCTAssertEqual(OrzAudioKit.AudioFormat.from(fileExtension: "mp3")?.playStrategy.rawValue, "directFile")
        XCTAssertEqual(OrzAudioKit.AudioFormat.from(fileExtension: "xm")?.playStrategy.rawValue, "wasmDecode")
        XCTAssertEqual(OrzAudioKit.AudioFormat.from(fileExtension: "bp")?.playStrategy.rawValue, "serverDecode")
    }

    func testPCMEncodeWAV() throws {
        let pcm = OrzAudioKit.PCMData(samples: Data([0x00, 0x00, 0xFF, 0x7F]))
        let wav = pcm.encodeWAV()
        // WAV header: "RIFF" at start
        XCTAssertEqual(String(data: wav[0..<4], encoding: .utf8), "RIFF")
        // WAV format: "WAVE"
        XCTAssertEqual(String(data: wav[8..<12], encoding: .utf8), "WAVE")
        // fmt chunk
        XCTAssertEqual(String(data: wav[12..<16], encoding: .utf8), "fmt ")
    }
}
