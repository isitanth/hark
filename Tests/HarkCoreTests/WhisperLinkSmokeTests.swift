import HarkCore
import Testing

/// whisper.framework links and loads under `swift test`. No model, no audio.
@Suite struct WhisperLinkSmokeTests {
    @Test func systemInfoReportsMetal() {
        #expect(WhisperRuntime.hasMetal, "\(WhisperRuntime.systemInfo())")
    }

    @Test func frameworkLoadsFromTheBuildProducts() throws {
        let path = try #require(WhisperRuntime.libraryPath())
        #expect(path.hasSuffix("/whisper.framework/Versions/A/whisper"), "\(path)")
    }
}
