import AVFoundation
import Foundation
import HarkCore
import Testing

/// Roadmap step 8, the part that does not need every tier installed: what the Core ML encoder is actually
/// worth on this machine.
///
///     HARK_TEST_MODEL=<path to ggml-*.bin> HARK_TEST_BENCH=1 swift test --filter TranscriberBenchmarkTests
///
/// It decodes one real clip from `say` repeatedly, first as installed and then with the Core ML encoder moved
/// aside so whisper falls back to Metal for the encoder too. Same model, same audio, same `audio_ctx`; the
/// only difference is which silicon runs the encoder half.
///
/// The clip is speech rather than a tone because the decoder's cost scales with how much it finds to say, and
/// a tone would flatter both runs equally but represent neither.
enum Bench {
    static let isOn = ProcessInfo.processInfo.environment["HARK_TEST_BENCH"] != nil
    static var isAvailable: Bool { isOn && TestModel.isAvailable }
    /// Enough runs to see past the noise, few enough to stay a test rather than an errand.
    static let runs = 8
    static let resultPath = "/tmp/hark-bench-result.txt"

    static func clip() throws -> [Float] {
        let url = URL(filePath: "/tmp/hark-bench-clip.wav")
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let say = Process()
            say.executableURL = URL(filePath: "/usr/bin/say")
            say.arguments = [
                "-o", url.path(percentEncoded: false), "--data-format=LEF32@16000",
                "The quick brown fox jumps over the lazy dog, and then it runs back again across the field.",
            ]
            try say.run()
            say.waitUntilExit()
        }
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        guard let format,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    struct Result: Sendable {
        var timings: [Int]
        var text: String
        var median: Int { timings.isEmpty ? -1 : timings[timings.count / 2] }
    }

    static func time(_ transcriber: Transcriber, _ samples: [Float]) async throws -> Result {
        try await transcriber.prepare()
        _ = try await transcriber.transcribe(samples)  // discard the first, which still pays for caches
        var timings: [Int] = []
        var text = ""
        for _ in 0..<runs {
            text = try await transcriber.transcribe(samples).raw
            if let report = await transcriber.lastDecode { timings.append(report.ms) }
        }
        await transcriber.unload()
        return Result(timings: timings.sorted(), text: text)
    }

    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    /// Lowercased words, so the two runs can be compared without punctuation noise.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
    }
}

@Suite(.enabled(if: Bench.isAvailable), .serialized)
struct TranscriberBenchmarkTests {
    @Test func coreMLAgainstMetalOnTheSameClip() async throws {
        let installation = try #require(TestModel.installation)
        let samples = try Bench.clip()
        #expect(samples.count > 16_000, "the clip did not load")

        let encoder = ModelInstallation.coreMLEncoderURL(for: installation.weights)
        let parked = encoder.deletingLastPathComponent()
            .appending(path: "parked-\(encoder.lastPathComponent)", directoryHint: .isDirectory)
        let manager = FileManager.default
        #expect(
            manager.fileExists(atPath: encoder.path(percentEncoded: false)),
            "no Core ML encoder installed; this would measure Metal twice")

        let withCoreML = try await Bench.time(Transcriber(model: installation, language: .english), samples)

        try manager.moveItem(at: encoder, to: parked)
        defer { try? manager.moveItem(at: parked, to: encoder) }
        let metalOnly = try await Bench.time(Transcriber(model: installation, language: .english), samples)

        // Faster is only a win if it still transcribes. The two paths are not expected to agree word for word,
        // because Core ML pins `audio_ctx` to the full window while Metal scales it, and a different encoder
        // context decodes the same audio slightly differently. What must hold is that both actually heard the
        // sentence: the failure this guards against is a Core ML encoder returning an encoding the decoder
        // cannot read, which collapses the whole clip to one token.
        for (label, result) in [("core ml", withCoreML), ("metal", metalOnly)] {
            let heard = Bench.words(result.text)
            #expect(heard.count > 10, "\(label) decoded \(heard.count) words: \(result.text)")
            for anchor in ["quick", "brown", "fox", "across", "field"] {
                #expect(heard.contains(anchor), "\(label) lost \"\(anchor)\": \(result.text)")
            }
        }

        let seconds = Double(samples.count) / SampleBuffer.sampleRate
        let report = """
            \(installation.tier.rawValue), \(String(format: "%.1f", seconds)) s clip, \(Bench.runs) runs
              Core ML  min \(withCoreML.timings.first ?? -1)  median \(withCoreML.median)  max \(withCoreML.timings.last ?? -1) ms
              Metal    min \(metalOnly.timings.first ?? -1)  median \(metalOnly.median)  max \(metalOnly.timings.last ?? -1) ms
              core ml text  \(withCoreML.text)
              metal text    \(metalOnly.text)
              clip rms      \(String(format: "%.4f", Bench.rms(samples)))
            """
        // Written out rather than recorded as an issue, so reporting a measurement does not fail the run.
        try? report.write(to: URL(filePath: Bench.resultPath), atomically: true, encoding: .utf8)
        #expect(!withCoreML.timings.isEmpty && !metalOnly.timings.isEmpty)
    }
}
