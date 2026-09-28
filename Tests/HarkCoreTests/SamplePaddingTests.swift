import Foundation
import HarkCore
import Testing

struct PaddingCase: Sendable, CustomTestStringConvertible {
    let ms: Int
    let count: Int
    let padded: Int

    var testDescription: String { "\(ms) ms" }
}

/// 16 samples per millisecond at 16 kHz.
let paddingCases: [PaddingCase] = [
    .init(ms: 0, count: 0, padded: 20_000),
    .init(ms: 249, count: 3_984, padded: 20_000),
    .init(ms: 250, count: 4_000, padded: 20_000),
    .init(ms: 999, count: 15_984, padded: 20_000),
    .init(ms: 1_000, count: 16_000, padded: 20_000),
    .init(ms: 1_001, count: 16_016, padded: 20_000),
    .init(ms: 1_249, count: 19_984, padded: 20_000),
    .init(ms: 1_250, count: 20_000, padded: 20_000),
    .init(ms: 1_251, count: 20_016, padded: 20_016),
    .init(ms: 5_000, count: 80_000, padded: 80_000),
]

@Suite struct SamplePaddingTests {
    @Test func minimumIsOneAndAQuarterSeconds() {
        #expect(SamplePadding.minimumSampleCount == 20_000)
        #expect(Double(SamplePadding.minimumSampleCount) / SampleBuffer.sampleRate == 1.25)
    }

    @Test(arguments: paddingCases)
    func padsToTheMinimum(_ padding: PaddingCase) {
        let clip = AudioSignal.sine(amplitude: 0.3, sampleRate: SampleBuffer.sampleRate, count: padding.count)
        let padded = SamplePadding.padded(clip)
        #expect(padded.count == padding.padded)
        #expect(SamplePadding.paddedCount(for: padding.count) == padding.padded)
    }

    @Test(arguments: paddingCases)
    func keepsTheClipAtTheHead(_ padding: PaddingCase) {
        let clip = AudioSignal.sine(amplitude: 0.3, sampleRate: SampleBuffer.sampleRate, count: padding.count)
        let padded = SamplePadding.padded(clip)
        #expect(Array(padded.prefix(padding.count)) == clip)
        #expect(padded.dropFirst(padding.count).allSatisfy { $0 == 0 })
    }

    @Test func aClipAtTheMinimumIsNotCopiedOrTruncated() {
        let clip = AudioSignal.square(amplitude: 0.5, count: SamplePadding.minimumSampleCount + 1)
        #expect(SamplePadding.padded(clip) == clip)
    }
}
