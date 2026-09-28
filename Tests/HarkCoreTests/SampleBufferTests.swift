import CoreAudio
import Foundation
import Testing

@testable import HarkCore

struct AppendPlan: Sendable, CustomTestStringConvertible {
    let chunks: [Int]
    let results: [Bool]
    let count: Int

    var testDescription: String { "chunks \(chunks)" }
}

@Suite struct SampleBufferTests {
    private let tenthOfASecond = Duration.milliseconds(100)

    @Test func emptyBuffer() {
        let buffer = SampleBuffer()
        #expect(buffer.samples.isEmpty)
        #expect(buffer.capacity == 28_800_000)
        #expect(!buffer.isFull)
        #expect(buffer.durationMs == 0)
        #expect(buffer.peakRMS == 0)
        #expect(buffer.meanRMS == 0)
        #expect(buffer.summary() == CaptureSummary(durationMs: 0, peakRMS: 0, meanRMS: 0, reachedMaxDuration: false))
    }

    @Test(arguments: [
        (Duration.seconds(60), 960_000),
        (.milliseconds(250), 4_000),
        (.milliseconds(100), 1_600),
        (.microseconds(125), 2),
        (.zero, 0),
        (.seconds(-1), 0),
    ])
    func capacityFollowsMaxDuration(_ maxDuration: Duration, _ capacity: Int) {
        #expect(SampleBuffer(maxDuration: maxDuration).capacity == capacity)
    }

    @Test func appendWithinCapacity() {
        var buffer = SampleBuffer(maxDuration: tenthOfASecond)
        let results = [buffer.append([Float](repeating: 0.1, count: 1_000)), buffer.append([])]
        #expect(results == [false, false])
        #expect(buffer.samples.count == 1_000)
        #expect(!buffer.isFull)
    }

    @Test(arguments: [
        AppendPlan(chunks: [1_600], results: [true], count: 1_600),
        AppendPlan(chunks: [2_000], results: [true], count: 1_600),
        AppendPlan(chunks: [1_000, 1_000, 10], results: [false, true, false], count: 1_600),
        AppendPlan(chunks: [1_599, 1, 1, 0], results: [false, true, false, false], count: 1_600),
        AppendPlan(chunks: [800, 799], results: [false, false], count: 1_599),
    ])
    func appendThatReachesCapacitySignalsOnce(_ plan: AppendPlan) {
        var buffer = SampleBuffer(maxDuration: tenthOfASecond)
        let results = plan.chunks.map { buffer.append([Float](repeating: 0.25, count: $0)) }
        #expect(results == plan.results)
        #expect(buffer.samples.count == plan.count)
        #expect(buffer.isFull == (plan.count == buffer.capacity))
    }

    @Test func samplesPastTheCapAreIgnored() {
        var buffer = SampleBuffer(maxDuration: tenthOfASecond)
        buffer.append([Float](repeating: 0.25, count: 1_600))
        let appended = buffer.append([Float](repeating: 0.9, count: 320))
        #expect(!appended)
        #expect(buffer.samples.count == 1_600)
        #expect(buffer.peakRMS == 0.25)
        #expect(buffer.meanRMS == 0.25)
    }

    @Test(arguments: [(0, 0), (15, 0), (16, 1), (320, 20), (3_984, 249), (4_000, 250), (16_000, 1_000)])
    func durationMs(_ count: Int, _ milliseconds: Int) {
        var buffer = SampleBuffer()
        buffer.append([Float](repeating: 0, count: count))
        #expect(buffer.durationMs == milliseconds)
    }

    @Test func constantSignal() {
        var buffer = SampleBuffer()
        buffer.append([Float](repeating: 0.5, count: 16_000))
        #expect(buffer.meanRMS == 0.5)
        #expect(buffer.peakRMS == 0.5)
    }

    @Test(arguments: [0.05, 0.3, 0.9] as [Float])
    func sineMeanRMSIsAmplitudeOverRootTwo(_ amplitude: Float) {
        var buffer = SampleBuffer()
        buffer.append(AudioSignal.sine(amplitude: amplitude, sampleRate: SampleBuffer.sampleRate, count: 16_000))
        #expect(abs(buffer.meanRMS - amplitude / Float(2).squareRoot()) < 1e-5)
    }

    /// 600 ms of room noise with one loud 20 ms window at 200 ms, fed in chunks that straddle window boundaries.
    @Test(arguments: [1, 7, 320, 333, 4_800])
    func peakRMSFindsTheLoudWindow(_ chunkSize: Int) {
        let loudStart = 10 * SampleBuffer.rmsWindow
        var signal = AudioSignal.square(amplitude: 0.001, count: 9_600)
        signal.replaceSubrange(
            loudStart..<loudStart + SampleBuffer.rmsWindow,
            with: AudioSignal.square(amplitude: 0.8, count: SampleBuffer.rmsWindow))

        var buffer = SampleBuffer()
        for start in stride(from: 0, to: signal.count, by: chunkSize) {
            buffer.append(signal[start..<min(start + chunkSize, signal.count)])
        }

        #expect(abs(buffer.peakRMS - 0.8) < 1e-6)
        #expect(abs(Double(buffer.meanRMS) - AudioSignal.rms(signal)) < 1e-6)
    }

    @Test func trailingPartialWindowCounts() {
        var buffer = SampleBuffer()
        buffer.append([Float](repeating: 0, count: SampleBuffer.rmsWindow))
        buffer.append([Float](repeating: 0.5, count: 100))
        #expect(buffer.peakRMS == 0.5)
    }

    @Test func resetKeepsCapacityAndClearsStats() {
        var buffer = SampleBuffer(maxDuration: tenthOfASecond)
        let filled = buffer.append([Float](repeating: 0.5, count: 1_600))
        #expect(filled)

        buffer.reset()
        #expect(buffer.samples.isEmpty)
        #expect(buffer.samples.capacity >= 1_600)
        #expect(buffer.capacity == 1_600)
        #expect(!buffer.isFull)
        #expect(buffer.summary() == CaptureSummary(durationMs: 0, peakRMS: 0, meanRMS: 0, reachedMaxDuration: false))

        buffer.append([Float](repeating: 0.1, count: 320))
        #expect(abs(buffer.peakRMS - 0.1) < 1e-6)
        let refilled = buffer.append([Float](repeating: 0.1, count: 1_280))
        #expect(refilled)
    }

    @Test(arguments: [
        (800, CaptureSummary(durationMs: 50, peakRMS: 0.25, meanRMS: 0.25, reachedMaxDuration: false)),
        (1_600, CaptureSummary(durationMs: 100, peakRMS: 0.25, meanRMS: 0.25, reachedMaxDuration: true)),
        (4_000, CaptureSummary(durationMs: 100, peakRMS: 0.25, meanRMS: 0.25, reachedMaxDuration: true)),
    ])
    func summary(_ count: Int, _ expected: CaptureSummary) {
        var buffer = SampleBuffer(maxDuration: tenthOfASecond)
        buffer.append(AudioSignal.square(amplitude: 0.25, count: count))
        #expect(buffer.summary() == expected)
    }
}

@Suite struct SampleBufferLimitTests {
    /// Thirty minutes of 16 kHz samples, and the limit `AudioCapture` uses when nothing else is asked for.
    @Test func theDefaultLimitIsThirtyMinutes() {
        #expect(SampleBuffer.defaultMaxDuration == .seconds(1_800))
        #expect(SampleBuffer().capacity == 28_800_000)
        #expect(SampleBuffer.reservedSampleCount == 960_000)
    }

    /// A recording within the reserved minute keeps its storage for the next press.
    @Test func aShortRecordingKeepsTheReservedStorage() {
        var buffer = SampleBuffer(maxDuration: .seconds(90))
        buffer.append([Float](repeating: 0.1, count: 480_000))
        buffer.reset()
        #expect(buffer.samples.isEmpty)
        #expect(buffer.samples.capacity >= SampleBuffer.reservedSampleCount)
    }

    /// One that grew past it gives the growth back.
    @Test func aLongRecordingReleasesWhatItGrewInto() {
        var buffer = SampleBuffer(maxDuration: .seconds(90))
        buffer.append([Float](repeating: 0.1, count: SampleBuffer.reservedSampleCount + 16_000))
        #expect(buffer.durationMs == 61_000)
        #expect(buffer.samples.capacity > SampleBuffer.reservedSampleCount)
        buffer.reset()
        #expect(buffer.samples.isEmpty)
        #expect(buffer.samples.capacity < SampleBuffer.reservedSampleCount)
    }
}

struct LevelPlan: Sendable, CustomTestStringConvertible {
    let name: String
    let chunks: [[Float]]
    let rms: Float

    var testDescription: String { name }

    static let burst = AudioSignal.square(amplitude: 0.5, count: SampleBuffer.rmsWindow)
    static let silentWindow = [Float](repeating: 0, count: SampleBuffer.rmsWindow)

    static func chunked(_ samples: [Float], by size: Int) -> [[Float]] {
        stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
    }

    static let all: [LevelPlan] = [
        LevelPlan(name: "silence", chunks: [[Float](repeating: 0, count: 16_000)], rms: 0),
        LevelPlan(name: "aligned burst", chunks: [silentWindow, burst, silentWindow], rms: 0.5),
        LevelPlan(
            name: "burst split across appends",
            chunks: [silentWindow, Array(burst.prefix(160)), Array(burst.suffix(160)), silentWindow], rms: 0.5),
        LevelPlan(name: "10 ms burst, no window", chunks: [Array(burst.prefix(160))], rms: 0),
        LevelPlan(
            name: "chunks of 100", chunks: chunked(AudioSignal.square(amplitude: 0.25, count: 4_000), by: 100),
            rms: 0.25),
        LevelPlan(
            name: "chunks of 341", chunks: chunked(AudioSignal.square(amplitude: 0.25, count: 4_092), by: 341),
            rms: 0.25),
        LevelPlan(
            name: "chunks of 1024", chunks: chunked(AudioSignal.square(amplitude: 0.25, count: 5_120), by: 1_024),
            rms: 0.25),
    ]
}

@Suite struct SampleBufferLevelTests {
    @Test(arguments: LevelPlan.all)
    func takeLevelReturnsTheLoudestCompletedWindowThenClears(_ plan: LevelPlan) {
        var buffer = SampleBuffer()
        for chunk in plan.chunks { buffer.append(chunk) }
        let first = buffer.takeLevel()
        #expect(abs(first.rms - plan.rms) < 1e-4)
        #expect(first.durationMs == buffer.durationMs)
        #expect(buffer.takeLevel() == LevelReading(rms: 0, durationMs: first.durationMs))
    }

    @Test func aPeakIsReadOnce() {
        var buffer = SampleBuffer()
        buffer.append(AudioSignal.square(amplitude: 0.8, count: SampleBuffer.rmsWindow))
        #expect(abs(buffer.takeLevel().rms - 0.8) < 1e-4)
        buffer.append(AudioSignal.square(amplitude: 0.1, count: SampleBuffer.rmsWindow))
        #expect(abs(buffer.takeLevel().rms - 0.1) < 1e-4)
    }

    @Test func takeLevelLeavesTheSummaryAlone() {
        var buffer = SampleBuffer()
        buffer.append(AudioSignal.square(amplitude: 0.8, count: SampleBuffer.rmsWindow))
        buffer.append(AudioSignal.square(amplitude: 0.2, count: 500))
        let before = buffer.summary()
        _ = buffer.takeLevel()
        #expect(buffer.summary() == before)
    }

    @Test func resetClearsTheLevel() {
        var buffer = SampleBuffer()
        buffer.append(AudioSignal.square(amplitude: 0.8, count: SampleBuffer.rmsWindow))
        buffer.reset()
        #expect(buffer.takeLevel() == LevelReading(rms: 0, durationMs: 0))
    }
}

@Suite struct CaptureSinkLevelTests {
    @Test func levelIsReadOnlyWhileArmed() {
        let (_, continuation) = AsyncStream.makeStream(of: AudioInputEvent.self)
        let sink = CaptureSink(maxDuration: .seconds(60), continuation: continuation)
        #expect(sink.takeLevel() == nil)
        sink.arm(UtteranceID(1))
        #expect(sink.takeLevel() == LevelReading(rms: 0, durationMs: 0))
        _ = sink.disarm()
        #expect(sink.takeLevel() == nil)
    }

    @Test func theSpectrumWindowNeedsAnArmedCaptureAndABuffer() {
        let (_, continuation) = AsyncStream.makeStream(of: AudioInputEvent.self)
        let sink = CaptureSink(maxDuration: .seconds(60), continuation: continuation)
        #expect(sink.window(count: 1_024, at: .now) == nil)
        sink.arm(UtteranceID(1))
        #expect(sink.window(count: 1_024, at: .now) == nil, "no buffer has landed yet")
        _ = sink.disarm()
        #expect(sink.window(count: 1_024, at: .now) == nil)
    }

    @Test func theTailIsTakenOnlyWhileArmed() {
        let (_, continuation) = AsyncStream.makeStream(of: AudioInputEvent.self)
        let sink = CaptureSink(maxDuration: .seconds(60), continuation: continuation)
        #expect(sink.takeTail(maxSamples: 96_000, minimumRMS: 0.01) == nil)
        sink.arm(UtteranceID(1))
        #expect(sink.takeTail(maxSamples: 96_000, minimumRMS: 0.01) == nil, "nothing captured yet")
        _ = sink.disarm()
        #expect(sink.takeTail(maxSamples: 96_000, minimumRMS: 0.01) == nil)
    }
}

@Suite struct SampleBufferWindowTests {
    static func ramp(_ count: Int) -> SampleBuffer {
        var buffer = SampleBuffer()
        buffer.append((0..<count).map { Float($0) })
        return buffer
    }

    @Test(arguments: [
        (2_000, 2_000, 1_024, 976..<2_000),
        (2_000, 1_000, 1_024, 0..<1_000),
        (2_000, 2_500, 1_024, 976..<2_000),
        (2_000, -5, 1_024, 0..<0),
        (2_000, 2_000, 0, 2_000..<2_000),
        (0, 0, 1_024, 0..<0),
    ])
    func theWindowIsClampedToWhatIsThere(_ count: Int, _ end: Int, _ size: Int, _ expected: Range<Int>) {
        #expect(Self.ramp(count).window(endingAt: end, count: size) == expected.map { Float($0) })
    }

    /// The case `Array(samples[...])` gets wrong: a window over the whole buffer must still be a copy, or the tap's
    /// next append would copy the whole reservation under the sink's lock.
    @Test(arguments: [1_024, 3_000])
    func theWindowNeverSharesTheBuffersStorage(_ count: Int) {
        var buffer = Self.ramp(count)
        let window = buffer.window(endingAt: count, count: 1_024)
        let shared = window.withUnsafeBufferPointer { copy in
            buffer.samples.withUnsafeBufferPointer { $0.baseAddress == copy.baseAddress }
        }
        #expect(!shared)
        buffer.append([Float](repeating: 0, count: 320))
        #expect(window == (count - 1_024..<count).map { Float($0) }, "an append does not reach the copy")
    }
}

@Suite struct SampleBufferTailTests {
    static let gate: Float = 0.01

    static func ramp(_ count: Int) -> SampleBuffer {
        var buffer = SampleBuffer()
        buffer.append((0..<count).map { Float($0) })
        return buffer
    }

    @Test(arguments: [
        (500, 1_024, 0..<500),
        (1_024, 1_024, 0..<1_024),
        (3_000, 1_024, 1_976..<3_000),
    ])
    func theTailIsTheLastSamples(_ count: Int, _ size: Int, _ expected: Range<Int>) {
        var buffer = Self.ramp(count)
        #expect(buffer.takeTail(maxSamples: size, minimumRMS: Self.gate) == expected.map { Float($0) })
    }

    @Test func anEmptyBufferHasNoTail() {
        var buffer = SampleBuffer()
        #expect(buffer.takeTail(maxSamples: 1_024, minimumRMS: Self.gate) == nil)
    }

    @Test func silenceSinceTheLastTakeGivesNothing() {
        var buffer = SampleBuffer()
        buffer.append(AudioSignal.square(amplitude: 0.5, count: SampleBuffer.rmsWindow))
        #expect(buffer.takeTail(maxSamples: 1_024, minimumRMS: Self.gate)?.count == SampleBuffer.rmsWindow)
        #expect(buffer.takeTail(maxSamples: 1_024, minimumRMS: Self.gate) == nil, "nothing new")
        buffer.append(AudioSignal.square(amplitude: 0.005, count: 3_200))
        #expect(buffer.takeTail(maxSamples: 1_024, minimumRMS: Self.gate) == nil, "below the gate")
        buffer.append([Float](repeating: 0, count: 3_200))
        #expect(buffer.takeTail(maxSamples: 1_024, minimumRMS: Self.gate) == nil)
    }

    @Test func aBurstSinceTheLastTakeGivesTheTail() {
        var buffer = SampleBuffer()
        buffer.append([Float](repeating: 0, count: 3_200))
        #expect(buffer.takeTail(maxSamples: 1_024, minimumRMS: Self.gate) == nil)
        buffer.append(AudioSignal.square(amplitude: 0.02, count: SampleBuffer.rmsWindow))
        buffer.append([Float](repeating: 0, count: 3_200))
        let tail = buffer.takeTail(maxSamples: 1_024, minimumRMS: Self.gate)
        #expect(tail == [Float](repeating: 0, count: 1_024), "the last samples, not the burst")
    }

    @Test func theTailAndTheLevelKeepTheirOwnPeaks() {
        var buffer = SampleBuffer()
        buffer.append(AudioSignal.square(amplitude: 0.5, count: SampleBuffer.rmsWindow))
        _ = buffer.takeLevel()
        _ = buffer.takeLevel()
        #expect(buffer.takeTail(maxSamples: 1_024, minimumRMS: Self.gate) != nil, "the hud's reads do not starve it")

        buffer.append(AudioSignal.square(amplitude: 0.5, count: SampleBuffer.rmsWindow))
        #expect(buffer.takeTail(maxSamples: 1_024, minimumRMS: Self.gate) != nil)
        #expect(abs(buffer.takeLevel().rms - 0.5) < 1e-4, "a take does not clear the level")
    }

    @Test func resetClearsTheTailsPeak() {
        var buffer = SampleBuffer()
        buffer.append(AudioSignal.square(amplitude: 0.5, count: SampleBuffer.rmsWindow))
        buffer.reset()
        #expect(buffer.takeTail(maxSamples: 1_024, minimumRMS: Self.gate) == nil)
    }

    /// While the capture holds fewer samples than the tail, the first 6 s of every recording, a slice would be the
    /// whole buffer and `Array` would hand its storage back; the tap's next append would then copy it under the lock.
    @Test(arguments: [500, 3_000])
    func theTailNeverSharesTheBuffersStorage(_ count: Int) throws {
        var buffer = Self.ramp(count)
        let taken = buffer.takeTail(maxSamples: 1_024, minimumRMS: Self.gate)
        let tail = try #require(taken)
        buffer.append([Float](repeating: 0, count: 320))
        let tailBase = tail.withUnsafeBufferPointer { $0.baseAddress }
        let bufferBase = buffer.samples.withUnsafeBufferPointer { $0.baseAddress }
        #expect(tailBase != bufferBase)
        #expect(tail == (max(count - 1_024, 0)..<count).map { Float($0) }, "an append does not reach the copy")
    }
}

@Suite struct CaptureSinkConsumeTests {
    private static func ramp(_ range: Range<Int>) -> [Float] {
        range.map { Float($0) }
    }

    @Test func consumedSamplesReachEveryReader() throws {
        let (_, continuation) = AsyncStream.makeStream(of: AudioInputEvent.self)
        let sink = CaptureSink(maxDuration: .seconds(60), continuation: continuation)
        sink.arm(UtteranceID(1))
        sink.consume(UtteranceID(1), [Float](repeating: 0.5, count: 640))
        let level = try #require(sink.takeLevel())
        #expect(abs(level.rms - 0.5) < 0.001)
        #expect(sink.takeTail(maxSamples: 1_000, minimumRMS: 0.01)?.count == 640)
        #expect(sink.window(count: 160, at: .now + .seconds(1)) == [Float](repeating: 0.5, count: 160))
        #expect(sink.disarm().samples.count == 640)
    }

    @Test func nothingIsAppendedWhileNotArmedOrForAnotherUtterance() {
        let (_, continuation) = AsyncStream.makeStream(of: AudioInputEvent.self)
        let sink = CaptureSink(maxDuration: .seconds(60), continuation: continuation)
        sink.consume(UtteranceID(1), [Float](repeating: 0.5, count: 320))
        sink.arm(UtteranceID(2))
        sink.consume(UtteranceID(1), [Float](repeating: 0.5, count: 320))
        #expect(sink.window(count: 160, at: .now) == nil, "a stale session's buffer lands nowhere")
        #expect(sink.disarm().samples.isEmpty)
        sink.consume(UtteranceID(2), [Float](repeating: 0.5, count: 320))
        #expect(sink.takeLevel() == nil)
        sink.arm(UtteranceID(3))
        #expect(sink.disarm().samples.isEmpty, "arming starts from an empty buffer")
    }

    @Test func theLimitIsReportedOnceAndNothingFollowsIt() async {
        let (events, continuation) = AsyncStream.makeStream(of: AudioInputEvent.self)
        let sink = CaptureSink(maxDuration: .milliseconds(100), continuation: continuation)
        sink.arm(UtteranceID(1))
        for _ in 0..<3 { sink.consume(UtteranceID(1), [Float](repeating: 0.25, count: 1_000)) }
        continuation.finish()
        var reached: [UtteranceID] = []
        for await event in events {
            if case .reachedMaxDuration(let id, let summary) = event {
                reached.append(id)
                #expect(summary.reachedMaxDuration)
            }
        }
        #expect(reached == [UtteranceID(1)])
        #expect(sink.disarm().samples.count == 1_600)
    }

    @Test func theNewestBufferPlacesTheWindow() {
        let (_, continuation) = AsyncStream.makeStream(of: AudioInputEvent.self)
        let sink = CaptureSink(maxDuration: .seconds(60), continuation: continuation)
        sink.arm(UtteranceID(1))
        sink.consume(UtteranceID(1), Self.ramp(0..<320))
        sink.consume(UtteranceID(1), Self.ramp(320..<480))
        #expect(sink.window(count: 160, at: .now - .seconds(1)) == Self.ramp(160..<320), "the newest buffer unplayed")
        #expect(sink.window(count: 160, at: .now + .seconds(1)) == Self.ramp(320..<480), "the newest buffer played")
    }
}

@Suite struct CaptureFormatTests {
    private static let expected = AudioStreamBasicDescription(
        mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
        mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)

    @Test func theAskedForFormatIsAccepted() {
        #expect(SampleDelegate.isExpected(Self.expected))
    }

    @Test(arguments: ["rate", "channels", "integer", "depth", "format"])
    func anyOtherFormatIsRefused(_ change: String) {
        var format = Self.expected
        switch change {
        case "rate": format.mSampleRate = 48_000
        case "channels": format.mChannelsPerFrame = 2
        case "integer": format.mFormatFlags = kAudioFormatFlagIsSignedInteger
        case "depth": format.mBitsPerChannel = 16
        default: format.mFormatID = kAudioFormatMPEG4AAC
        }
        #expect(!SampleDelegate.isExpected(format))
    }
}
