import Darwin
import Foundation
import HarkCore
import Testing

/// M7.0's premises for the live text, measured on the real model before any code relies on them:
///
///     HARK_TEST_MODEL=<path to ggml-small-q8_0.bin> HARK_TEST_BENCH=1 swift test --filter LiveTextPremiseTests
///
/// The live text re-decodes the last 6 s on a second, resident Small context, and meets the final's context only
/// on the GPU and the Neural Engine. What has to hold: two contexts decode at once and both return their text, and
/// a final started while a partial is still running is not held back by much. Each test writes its numbers to
/// `/tmp/hark-premise-<name>.txt`, which docs/acceptance/M7.md records; only the text is asserted.
@Suite(.enabled(if: Bench.isAvailable), .serialized, .timeLimit(.minutes(5)))
struct LiveTextPremiseTests {
    /// 4.4 s with Samantha, padded with silence to the 5 s question 5 is asked about.
    static let finalText = "Please send the quarterly report to Julian before Friday, and copy Mary."
    static let finalMarks = ["quarterly", "report", "friday", "mary"]
    /// 9.1 s; the partial gets its last 6 s, cut wherever that falls, as a live tail is.
    static let tailText = """
        Two positions have been open since July, and we have received very few serious applications, so the \
        recruiting firm advised us to raise the salary range.
        """
    static let tailMarks = ["recruiting", "salary", "range"]
    /// Offsets swept between the partial's start and the key up, from 0 to one encode.
    static let offsets = 20

    /// One Core ML encode, bounded above by a decode of 2 s of silence (mel, the encode, and the few decoder steps
    /// whisper takes to give up on nothing), and one partial: a decode of the 6 s tail.
    @Test func oneEncodeAndOnePartial() async throws {
        let transcriber = try Self.transcriber()
        try await transcriber.prepare()
        let encode = try await Self.decodeTimes(transcriber, Self.silence)
        let partial = try await Self.decodeTimes(transcriber, try Self.tail())
        await transcriber.shutdown()

        Self.expect(partial.text, heard: Self.tailMarks, "the partial")
        Self.write(
            "encode-and-partial",
            """
            one encode (2 s of silence, upper bound): \(Self.spread(encode.timings)) ms, text <\(encode.text)>
            one partial (6 s tail): \(Self.spread(partial.timings)) ms
              text: \(partial.text)
            """)
    }

    /// Two Small contexts in one process, each on its own serial queue, decoding different clips at the same time:
    /// both return their text, and the final's time with a whole partial beside it is the worst case the plan names.
    /// Also the second context's load, warm-up and memory, measured with the first already resident.
    @Test func twoContextsDecodeAtOnce() async throws {
        let first = try Self.transcriber()
        let second = try Self.transcriber()
        let empty = Self.footprintMB()
        let firstLoad = try await Self.wallMs { try await first.prepare() }
        let one = Self.footprintMB()
        let secondLoad = try await Self.wallMs { try await second.prepare() }
        let two = Self.footprintMB()

        let clip = try Self.finalClip()
        let tail = try Self.tail()
        var finals: [Int] = []
        var partials: [Int] = []
        for round in 1...Bench.runs {
            async let a = Self.timed { try await first.transcribe(clip).raw }
            async let b = Self.timed { try await second.transcribe(tail).raw }
            let (final, partial) = try await (a, b)
            finals.append(final.ms)
            partials.append(partial.ms)
            Self.expect(final.value, heard: Self.finalMarks, "round \(round), first context")
            Self.expect(partial.value, heard: Self.tailMarks, "round \(round), second context")
        }
        await first.shutdown()
        await second.shutdown()

        Self.write(
            "two-contexts",
            """
            first context: load and warm-up \(firstLoad) ms, footprint \(empty) -> \(one) MB
            second context: load and warm-up \(secondLoad) ms, footprint \(one) -> \(two) MB (+\(two - one) MB)
            started together, \(Bench.runs) rounds, neither cancelled (the worst case for the final):
              the final, 5 s clip: \(Self.spread(finals)) ms
              the partial, 6 s tail: \(Self.spread(partials)) ms
            """)
    }
}

extension LiveTextPremiseTests {
    /// Question 5's numbers. The app, on key up, cancels the partial and starts the final. A partial's Core ML
    /// encode cannot be cut short, so a final that starts while one runs may wait for it. The final's wall time on
    /// the 5 s clip, alone, then with a partial started on the other context `offset` before the key up, for 20
    /// offsets from 0 to one encode. At 0 the cancel can land before the partial's `begin()`, which clears it, and
    /// that partial then runs to the end: the worst case the plan names.
    @Test func theFinalWithAPartialStillRunningAtKeyUp() async throws {
        let final = try Self.transcriber()
        let partial = try Self.transcriber()
        try await final.prepare()
        try await partial.prepare()
        let clip = try Self.finalClip()
        let tail = try Self.tail()
        let encode = try await Self.decodeTimes(partial, Self.silence).median

        _ = try await final.transcribe(clip)
        var alone: [Int] = []
        for run in 1...Self.offsets {
            let started = ContinuousClock.now
            let text = try await final.transcribe(clip).raw
            alone.append(Self.ms(started.duration(to: .now)))
            Self.expect(text, heard: Self.finalMarks, "alone, run \(run)")
        }

        var shared: [Int] = []
        var rows: [String] = []
        for index in 0..<Self.offsets {
            let offset = encode * index / (Self.offsets - 1)
            let started = ContinuousClock.now
            let running = Task { try await partial.transcribe(tail) }
            try await Task.sleep(until: started + .milliseconds(offset), tolerance: .zero, clock: .continuous)
            await partial.cancel()
            let keyUp = ContinuousClock.now
            let text = try await final.transcribe(clip).raw
            let wall = Self.ms(keyUp.duration(to: .now))
            let partialText = try await running.value.raw
            shared.append(wall)
            Self.expect(text, heard: Self.finalMarks, "offset \(offset) ms")
            rows.append(
                "offset \(offset) ms (actual \(Self.ms(started.duration(to: keyUp)))): final \(wall) ms, "
                    + "partial \(partialText.isEmpty ? "aborted" : "ran to the end")")
        }
        await final.shutdown()
        await partial.shutdown()

        let baseline = Self.median(alone)
        Self.write(
            "final-with-partial",
            """
            encode (2 s of silence, median): \(encode) ms
            final alone, 5 s clip: \(Self.spread(alone)) ms
            final with a partial running at key up: \(Self.spread(shared)) ms
            later than alone (against its median): up to \(shared.max().map { $0 - baseline } ?? -1) ms, \
            typically \(Self.median(shared) - baseline) ms
            \(rows.joined(separator: "\n"))
            """)
    }

    // MARK: Helpers

    static let silence = [Float](repeating: 0, count: 2 * Int(SampleBuffer.sampleRate))

    static func transcriber() throws -> Transcriber {
        Transcriber(model: try #require(TestModel.installation), language: .english)
    }

    static func finalClip() throws -> [Float] {
        let speech = try TestModel.speech(finalText, voice: "Samantha", in: try TemporaryDirectory())
        let count = 5 * Int(SampleBuffer.sampleRate)
        try #require(speech.count <= count, "the final's sentence runs past 5 s")
        return speech + [Float](repeating: 0, count: count - speech.count)
    }

    static func tail() throws -> [Float] {
        let speech = try TestModel.speech(tailText, voice: "Samantha", in: try TemporaryDirectory())
        let count = 6 * Int(SampleBuffer.sampleRate)
        try #require(speech.count > count, "the tail's sentence is shorter than 6 s")
        return Array(speech.suffix(count))
    }

    /// One warm decode, then `Bench.runs` timed by whisper's own clock (`lastDecode.ms`), sorted.
    static func decodeTimes(_ transcriber: Transcriber, _ samples: [Float]) async throws -> Bench.Result {
        _ = try await transcriber.transcribe(samples)
        var timings: [Int] = []
        var text = ""
        for _ in 0..<Bench.runs {
            text = try await transcriber.transcribe(samples).raw
            if let report = await transcriber.lastDecode { timings.append(report.ms) }
        }
        return Bench.Result(timings: timings.sorted(), text: text)
    }

    static func timed<T: Sendable>(_ body: () async throws -> T) async throws -> (value: T, ms: Int) {
        let started = ContinuousClock.now
        let value = try await body()
        return (value, ms(started.duration(to: .now)))
    }

    static func wallMs(_ body: () async throws -> Void) async throws -> Int {
        let started = ContinuousClock.now
        try await body()
        return ms(started.duration(to: .now))
    }

    static func ms(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    static func median(_ values: [Int]) -> Int {
        values.isEmpty ? -1 : values.sorted()[values.count / 2]
    }

    static func spread(_ values: [Int]) -> String {
        let sorted = values.sorted()
        return "min \(sorted.first ?? -1), median \(median(sorted)), max \(sorted.last ?? -1)"
    }

    /// The process's physical footprint, as Activity Monitor's Memory column counts it.
    static func footprintMB() -> Int {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int(usage.ri_phys_footprint / 1_048_576) : -1
    }

    static func expect(_ text: String, heard marks: [String], _ label: String) {
        let heard = Bench.words(text)
        for mark in marks {
            #expect(heard.contains(mark), "\(label) lost \"\(mark)\": \(text)")
        }
    }

    /// Written out rather than recorded as an issue, so reporting a measurement does not fail the run.
    static func write(_ name: String, _ report: String) {
        try? report.write(to: URL(filePath: "/tmp/hark-premise-\(name).txt"), atomically: true, encoding: .utf8)
    }
}
