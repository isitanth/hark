import Foundation
import HarkCore
import Testing

/// Two real captures on the current default input, through AVCaptureSession. Off unless `HARK_TEST_MIC` is set:
///
///     HARK_TEST_MIC=1 swift test --filter CaptureSmokeTests
///
/// It opens the default input for a second, twice, and changes no setting. The first proves the session delivers
/// 16 kHz samples; the second that a released session leaves nothing behind that stops the next press.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["HARK_TEST_MIC"] != nil), .serialized, .timeLimit(.minutes(1)))
struct CaptureSmokeTests {
    @Test func twoCapturesInARowDeliverSamples() async throws {
        let capture = AudioCapture()
        await capture.prepare()
        for raw in UInt64(1)...2 {
            let id = UtteranceID(raw)
            try await capture.start(id)
            try await Task.sleep(for: .seconds(1))
            let audio = try await capture.stop(id)
            #expect(audio.samples.count > 12_000, "capture \(raw): \(audio.samples.count) samples")
        }
    }
}
