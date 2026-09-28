import AVFoundation
import Foundation
import HarkCore
import Testing

/// The only tests that load a real model and drive whisper end to end.
///
/// They are off unless `HARK_TEST_MODEL` points at a ggml file, because the weights are a gigabyte and live
/// outside the repo:
///
///     HARK_TEST_MODEL=~/Library/Application\ Support/Hark/models/ggml-small-q8_0.bin swift test
///
/// Everything else about the transcriber is covered by DecodeSpecTests, SamplePaddingTests and
/// HallucinationFilterTests, which need no model. What only a real decode can show is that the C binding holds
/// together: that the model loads, that a clip shorter than whisper's floor still comes back, that a scaled
/// `audio_ctx` decodes instead of returning nothing, and that cancel and unload leave the actor usable.
enum TestModel {
    static let path = ProcessInfo.processInfo.environment["HARK_TEST_MODEL"]
        .map { NSString(string: $0).expandingTildeInPath }

    static var isAvailable: Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// The tier only labels the log line here, so the filename is enough to guess it.
    static var installation: ModelInstallation? {
        guard let path else { return nil }
        let weights = URL(filePath: path)
        let name = weights.lastPathComponent
        let tier: ModelTier =
            name.contains("large") ? .large : (name.contains("medium") ? .medium : .small)
        let encoder = ModelInstallation.coreMLEncoderURL(for: weights)
        let hasEncoder = FileManager.default.fileExists(atPath: encoder.path(percentEncoded: false))
        return ModelInstallation(tier: tier, weights: weights, coreMLEncoder: hasEncoder ? encoder : nil)
    }

    static func tone(seconds: Double, frequency: Double = 220, amplitude: Float = 0.2) -> [Float] {
        let rate = SampleBuffer.sampleRate
        return AudioSignal.sine(
            frequency: frequency, amplitude: amplitude, sampleRate: rate, count: Int(seconds * rate))
    }

    /// `say` to AIFF, `afconvert` to 16 kHz mono float, read back as samples.
    static func speech(_ text: String, voice: String, in directory: TemporaryDirectory) throws -> [Float] {
        let aiff = directory.url.appending(path: "\(UUID().uuidString).aiff")
        let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
        try run("/usr/bin/say", ["-v", voice, "-o", aiff.path(percentEncoded: false), text])
        try run(
            "/usr/bin/afconvert",
            [
                "-f", "WAVE", "-d", "LEF32@16000", "-c", "1", aiff.path(percentEncoded: false),
                wav.path(percentEncoded: false),
            ])
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(tool) exited \(process.terminationStatus)")
    }
}

@Suite(.enabled(if: TestModel.isAvailable), .serialized)
struct TranscriberSmokeTests {
    private func makeTranscriber(language: TranscriptionLanguage = .english) throws -> Transcriber {
        let installation = try #require(TestModel.installation)
        return Transcriber(model: installation, language: language)
    }

    @Test func modelLoadsAndWarmsUp() async throws {
        let transcriber = try makeTranscriber()
        try await transcriber.prepare()
        #expect(await transcriber.isLoaded())
        await transcriber.unload()
        #expect(await transcriber.isLoaded() == false)
    }

    /// The reviewer blocker this whole test file exists for: whisper returns nothing for clips under about a
    /// second, so `SamplePadding` has to pad before the encoder ever sees them. A 0.6 s press is a real one.
    @Test func aClipShorterThanWhispersFloorStillDecodes() async throws {
        let transcriber = try makeTranscriber()
        _ = try await transcriber.transcribe(TestModel.tone(seconds: 0.6))

        let report = try #require(await transcriber.lastDecode)
        #expect(
            report.sampleCount >= SamplePadding.minimumSampleCount,
            "0.6 s must reach the encoder padded, not raw")
        #expect(report.ms > 0)
    }

    /// `audio_ctx` scaled to the clip is the milestone's latency lever, and the failure mode is silent: too
    /// small and the decoder emits garbage rather than erroring. A real decode is the only place it is proven
    /// that the scaled value is one whisper actually accepts.
    @Test func audioContextScalesWithTheClipAndStillDecodes() async throws {
        let transcriber = try makeTranscriber()

        _ = try await transcriber.transcribe(TestModel.tone(seconds: 1))
        let short = try #require(await transcriber.lastDecode)

        _ = try await transcriber.transcribe(TestModel.tone(seconds: 6))
        let long = try #require(await transcriber.lastDecode)

        #expect(long.audioContext <= DecodeSpec.fullAudioContext)
        #expect(short.audioContext >= DecodeSpec.minimumAudioContext)

        // Which behaviour is correct depends on what is installed beside the weights. The Core ML encoder is
        // compiled for the whole window, so its presence pins both clips there; without it the context scales.
        let installation = try #require(TestModel.installation)
        if installation.coreMLEncoder != nil {
            #expect(short.audioContext == DecodeSpec.fullAudioContext)
            #expect(long.audioContext == DecodeSpec.fullAudioContext)
        } else {
            #expect(short.audioContext < long.audioContext)
        }
    }

    /// A tone is not speech. Whatever whisper invents over it, the filter has to blank, or the pipeline would
    /// resolve an utterance the user never made.
    @Test func silenceComesBackBlankRatherThanInvented() async throws {
        let transcriber = try makeTranscriber()
        let transcript = try await transcriber.transcribe(
            [Float](repeating: 0, count: Int(2 * SampleBuffer.sampleRate)))

        let report = try #require(await transcriber.lastDecode)
        #expect(
            transcript.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "whisper returned <\(transcript.raw)> for silence and nothing rejected it")
        #expect(report.rejection != nil, "silence must be rejected by name, not by luck")
        let tier = await transcriber.model.tier
        #expect(transcript.tier == tier, "a blank transcript still names the model that decoded it")
    }

    /// A clip past whisper's window is cut into chunks, and a long pause between them is skipped: the 35 s of
    /// silence between the tones never reaches the encoder. Tones are not speech, so only the shape is checked.
    @Test func aLongPauseIsSkippedRatherThanDecoded() async throws {
        let transcriber = try makeTranscriber()
        var samples = TestModel.tone(seconds: 20)
        samples += [Float](repeating: 0, count: Int(35 * SampleBuffer.sampleRate))
        samples += TestModel.tone(seconds: 15, frequency: 330)
        _ = try await transcriber.transcribe(samples)

        let report = try #require(await transcriber.lastDecode)
        #expect(report.chunks == 2, "two stretches of sound, got \(report.chunks) chunks")
        #expect(report.sampleCount < samples.count - 30 * Int(SampleBuffer.sampleRate))
        #expect(report.keptChunks <= report.chunks)
    }

    /// A key held over silence past the window: nothing is decoded and nothing is invented.
    @Test func silencePastTheWindowComesBackBlank() async throws {
        let transcriber = try makeTranscriber(language: .auto)
        let transcript = try await transcriber.transcribe(
            [Float](repeating: 0, count: Int(70 * SampleBuffer.sampleRate)))

        let report = try #require(await transcriber.lastDecode)
        #expect(transcript.raw.isEmpty, "silence decoded as \"\(transcript.raw)\"")
        #expect(report.keptChunks == 0 && report.sampleCount == 0)
    }

    /// Cancel arms a flag whisper reads between graph computes. What matters is that the actor survives it and
    /// the next utterance still works, since the trigger can be cancelled at any moment.
    @Test func cancelLeavesTheActorUsable() async throws {
        let transcriber = try makeTranscriber()
        try await transcriber.prepare()
        await transcriber.cancel()

        _ = try await transcriber.transcribe(TestModel.tone(seconds: 1))
        #expect(await transcriber.lastDecode != nil)
    }

    /// The live text's Small beside the final's: two whisper contexts decoding at once, each on its own queue.
    /// whisper.cpp forbids one context used from two threads, not two contexts, and neither waits for the other.
    @Test func twoSmallTranscribersDecodeAtTheSameTime() async throws {
        let directory = try TemporaryDirectory()
        let first = try TestModel.speech("Please send the report before lunch.", voice: "Samantha", in: directory)
        let second = try TestModel.speech("The weather is lovely this morning.", voice: "Samantha", in: directory)
        let final = try makeTranscriber()
        let partial = try makeTranscriber()
        try await final.prepare()
        try await partial.prepare()

        async let one = final.transcribe(first)
        async let two = partial.transcribe(second)
        let (a, b) = try await (one, two)

        #expect(a.raw.lowercased().contains("report"), "the final heard <\(a.raw)>")
        #expect(b.raw.lowercased().contains("weather"), "the partial heard <\(b.raw)>")
    }

    /// A partial decodes only the last 6 s of what is being said, often starting mid-word; it must still return
    /// the words at the end of that window rather than nothing.
    @Test func aPartialOnASixSecondTailReturnsText() async throws {
        let sentence =
            "This morning I walked along the river, stopped at the bakery for bread, and then I called my sister "
            + "to tell her that the meeting has moved to Thursday afternoon at three."
        let samples = try TestModel.speech(sentence, voice: "Samantha", in: try TemporaryDirectory())
        let tailCount = 6 * Int(SampleBuffer.sampleRate)
        try #require(samples.count > tailCount, "the sentence must be longer than the tail")
        let transcriber = try makeTranscriber()

        let transcript = try await transcriber.transcribe(Array(samples.suffix(tailCount)))

        #expect(!transcript.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(transcript.raw.lowercased().contains("thursday"), "the tail decoded as <\(transcript.raw)>")
    }
}
