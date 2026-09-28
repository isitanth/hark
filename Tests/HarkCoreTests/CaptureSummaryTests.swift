import Foundation
import HarkCore
import Testing

struct CaptureCase: Sendable, CustomTestStringConvertible {
    let name: String
    var maxDuration: Duration = .seconds(60)
    let samples: [Float]
    let reason: DiscardReason?

    var testDescription: String { name }
}

private func speech(_ count: Int) -> [Float] {
    AudioSignal.sine(amplitude: 0.3, sampleRate: SampleBuffer.sampleRate, count: count)
}

let captureCases: [CaptureCase] = [
    .init(name: "249 ms of speech is too short", samples: speech(3_984), reason: .tooShort),
    .init(name: "250 ms of speech is transcribed", samples: speech(4_000), reason: nil),
    .init(
        name: "249 ms of silence is too short first", samples: [Float](repeating: 0, count: 3_984), reason: .tooShort),
    .init(name: "1 s of digital silence", samples: [Float](repeating: 0, count: 16_000), reason: .noSpeech),
    .init(
        name: "1 s of room noise, peak RMS 0.0099", samples: AudioSignal.square(amplitude: 0.0099, count: 16_000),
        reason: .noSpeech),
    .init(name: "1 s at the RMS floor", samples: AudioSignal.square(amplitude: 0.01, count: 16_000), reason: nil),
    .init(
        name: "one 20 ms syllable over room noise",
        samples: AudioSignal.square(amplitude: 0.001, count: 8_000) + AudioSignal.square(amplitude: 0.05, count: 320)
            + AudioSignal.square(amplitude: 0.001, count: 8_000),
        reason: nil),
    .init(
        name: "buffer filled to the limit is transcribed", maxDuration: .milliseconds(500), samples: speech(8_000),
        reason: nil),
    .init(
        name: "speech past the limit is transcribed", maxDuration: .milliseconds(500), samples: speech(12_000),
        reason: nil),
    .init(
        name: "silence that fills the limit is silence", maxDuration: .milliseconds(500),
        samples: [Float](repeating: 0, count: 8_000), reason: .noSpeech),
]

@Suite struct CaptureSummaryTests {
    @Test(arguments: captureCases)
    func discardReason(_ capture: CaptureCase) {
        var buffer = SampleBuffer(maxDuration: capture.maxDuration)
        buffer.append(capture.samples)
        #expect(CapturePolicy.standard.discardReason(for: buffer.summary()) == capture.reason)
    }
}
