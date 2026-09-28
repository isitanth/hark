import Foundation
import HarkCore
import Testing

struct AudioContextCase: Sendable, CustomTestStringConvertible {
    let name: String
    let sampleCount: Int
    var modelAudioContext: Int = DecodeSpec.fullAudioContext
    let audioContext: Int

    var testDescription: String { name }
}

/// 320 samples per encoder state at 16 kHz: 16000 / 50.
let audioContextCases: [AudioContextCase] = [
    .init(name: "an empty clip still asks for one block", sampleCount: 0, audioContext: 256),
    .init(name: "the 1.25 s padding floor needs 63 states", sampleCount: 20_000, audioContext: 256),
    .init(name: "4.12 s is the last clip that fits one block", sampleCount: 65_920, audioContext: 256),
    .init(name: "one sample more crosses into two", sampleCount: 65_921, audioContext: 512),
    .init(name: "a 5 s clip", sampleCount: 80_000, audioContext: 512),
    .init(name: "9.24 s is the last clip that fits two", sampleCount: 147_840, audioContext: 512),
    .init(name: "one sample more crosses into three", sampleCount: 147_841, audioContext: 768),
    .init(name: "29 s reaches the full window", sampleCount: 464_000, audioContext: 1_500),
    .init(name: "the 60 s capture cap is clamped, not scaled", sampleCount: 960_000, audioContext: 1_500),
    .init(
        name: "a model with a shorter window clamps to it", sampleCount: 80_000, modelAudioContext: 448,
        audioContext: 448),
    .init(
        name: "a model reporting nothing falls back to the full window", sampleCount: 960_000, modelAudioContext: 0,
        audioContext: 1_500),
]

@Suite struct DecodeSpecTests {
    @Test(arguments: audioContextCases)
    func audioContextFollowsTheClip(_ expected: AudioContextCase) {
        let computed = DecodeSpec.audioContext(
            forSampleCount: expected.sampleCount, modelAudioContext: expected.modelAudioContext)
        #expect(computed == expected.audioContext)

        let spec = DecodeSpec(
            sampleCount: expected.sampleCount, language: .french, modelAudioContext: expected.modelAudioContext,
            processorCount: 10)
        #expect(spec.audioContext == expected.audioContext)
    }

    @Test func audioContextIsAlwaysAlignedAndWithinTheModel() {
        for hundredths in stride(from: 0, through: 6_000, by: 5) {
            let count = hundredths * Int(SampleBuffer.sampleRate) / 100
            let context = DecodeSpec.audioContext(forSampleCount: count)
            #expect(context >= DecodeSpec.minimumAudioContext)
            #expect(context <= DecodeSpec.fullAudioContext)
            #expect(context % DecodeSpec.audioContextAlignment == 0 || context == DecodeSpec.fullAudioContext)
            // The clip's own states must always fit, headroom or not.
            let states = count * DecodeSpec.encoderStatesPerSecond / Int(SampleBuffer.sampleRate)
            #expect(context >= min(states, DecodeSpec.fullAudioContext))
        }
    }

    @Test func audioContextNeverShrinksAsTheClipGrows() {
        var previous = 0
        for count in stride(from: 0, through: 960_000, by: 997) {
            let context = DecodeSpec.audioContext(forSampleCount: count)
            #expect(context >= previous)
            previous = context
        }
    }

    @Test(arguments: [(1, 1), (2, 2), (4, 4), (8, 4), (10, 4), (0, 1), (-3, 1)])
    func threadCountStopsAtFour(_ processors: Int, _ threads: Int) {
        let spec = DecodeSpec(sampleCount: 80_000, language: .auto, processorCount: processors)
        #expect(spec.threadCount == threads)
    }

    @Test func theDecodeIsGreedySingleSegmentAndSilent() {
        let spec = DecodeSpec(sampleCount: 80_000, language: .english, processorCount: 10)
        #expect(spec.noContext)
        #expect(spec.noTimestamps)
        #expect(spec.singleSegment)
        #expect(spec.suppressNonSpeechTokens)
        #expect(spec.suppressBlank)
        #expect(spec.bestOf == 1)
        #expect(spec.temperature == 0)
        #expect(spec.temperatureIncrement == 0)
        #expect(!spec.translate)
        #expect(!spec.tokenTimestamps)
        #expect(!spec.printSpecial)
        #expect(!spec.printProgress)
        #expect(!spec.printRealtime)
        #expect(!spec.printTimestamps)
        #expect(spec.language == .english)
    }

    @Test func languageIsCarriedInWhispersSpelling() {
        #expect(DecodeSpec(sampleCount: 20_000, language: .auto).language.whisperCode == "auto")
        #expect(DecodeSpec(sampleCount: 20_000, language: .french).language.whisperCode == "fr")
        #expect(DecodeSpec(sampleCount: 20_000, language: .english).language.whisperCode == "en")
    }

    @Test func noVocabularyMeansNoPrompt() {
        #expect(DecodeSpec.prompt(from: []) == nil)
        #expect(DecodeSpec.prompt(from: ["", "   ", "\n"]) == nil)
        #expect(DecodeSpec(sampleCount: 20_000, language: .auto, vocabulary: []).initialPrompt == nil)
    }

    @Test func thePromptIsTheVocabularyAsOneLabelledList() {
        let prompt = DecodeSpec.prompt(from: ["Open Finder", " ouvre le finder ", "open finder", "Start the VPN"])
        #expect(prompt == "Terms: Open Finder, ouvre le finder, Start the VPN.")
        let spec = DecodeSpec(sampleCount: 20_000, language: .french, vocabulary: ["ouvre le finder"])
        #expect(spec.initialPrompt == "Terms: ouvre le finder.")
    }

    @Test func thePromptStopsOnAPhraseBoundaryAtTheBudget() throws {
        let phrases = (0..<200).map { "command number \($0)" }
        let prompt = try #require(DecodeSpec.prompt(from: phrases))
        #expect(prompt.count <= DecodeSpec.promptCharacterBudget + 1)
        #expect(prompt.hasPrefix("Terms: command number 0, command number 1,"))
        #expect(prompt.hasSuffix("."))
        // Truncation never cuts a phrase in half.
        let kept = prompt.dropFirst(DecodeSpec.promptLabel.count).dropLast().components(separatedBy: ", ")
        #expect(kept.allSatisfy { phrases.contains($0) })
        #expect(kept.count < phrases.count)
    }

    /// The Core ML encoder is compiled for one input shape, the whole window. Asking for less does not fail —
    /// it returns an encoding the decoder cannot read, and a 5.7 s sentence comes back as a single token.
    /// Measured on small q8_0, 2026-09-21. So the presence of an encoder overrides the scaling entirely.
    @Test(arguments: [16_000, 48_000, 91_755, 480_000])
    func aCoreMLEncoderPinsTheContextToTheFullWindow(_ sampleCount: Int) {
        let scaled = DecodeSpec.audioContext(forSampleCount: sampleCount)
        let pinned = DecodeSpec.audioContext(forSampleCount: sampleCount, usesCoreMLEncoder: true)

        #expect(pinned == DecodeSpec.fullAudioContext)
        #expect(scaled <= pinned)
    }

    @Test func theSpecCarriesThePinnedContextThrough() {
        let spec = DecodeSpec(sampleCount: 48_000, language: .english, usesCoreMLEncoder: true)
        #expect(spec.audioContext == DecodeSpec.fullAudioContext)

        let scaled = DecodeSpec(sampleCount: 48_000, language: .english)
        #expect(scaled.audioContext < DecodeSpec.fullAudioContext)
    }

    /// A model that reports a smaller window than whisper's default still caps the pinned value.
    @Test func thePinIsStillClampedToWhatTheModelCanEncode() {
        let pinned = DecodeSpec.audioContext(
            forSampleCount: 480_000, modelAudioContext: 1_000, usesCoreMLEncoder: true)
        #expect(pinned == 1_000)
    }
}
