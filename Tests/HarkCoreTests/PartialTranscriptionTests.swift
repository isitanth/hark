import Foundation
import Testing
import os

@testable import HarkCore

/// A tail that answers from a queue, then with `fallback`, counts its takes and runs `onTake` inside each.
private final class FakeTail: AudioTailSource {
    private struct State {
        var answers: [[Float]?]
        var takes = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let fallback: [Float]?
    private let onTake: @Sendable () -> Void

    init(_ answers: [[Float]?] = [], fallback: [Float]? = [0.5], onTake: @escaping @Sendable () -> Void = {}) {
        state = OSAllocatedUnfairLock(initialState: State(answers: answers))
        self.fallback = fallback
        self.onTake = onTake
    }

    var takes: Int { state.withLock { $0.takes } }

    func takeTail(maxSamples: Int, minimumRMS: Float) -> [Float]? {
        onTake()
        return state.withLock { state in
            state.takes += 1
            return state.answers.isEmpty ? fallback : state.answers.removeFirst()
        }
    }
}

/// An engine that answers from a script and can hold a decode open until the test releases it.
private actor FakeEngine: TranscriptionEngine {
    enum Outcome {
        case text(String)
        case fail
        case held(String)
    }

    private var script: [Outcome]
    private(set) var calls = 0
    private(set) var cancels = 0
    private var held: CheckedContinuation<Void, Never>?
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ script: [Outcome] = []) {
        self.script = script
    }

    func transcribe(_ samples: [Float]) async throws(PipelineFailure) -> Transcript {
        calls += 1
        let met = callWaiters.filter { $0.count <= calls }
        callWaiters.removeAll { $0.count <= calls }
        for waiter in met { waiter.continuation.resume() }
        switch script.isEmpty ? .text("more") : script.removeFirst() {
        case .text(let text):
            return Transcript(raw: text)
        case .fail:
            throw .transcription(code: -1)
        case .held(let text):
            await withCheckedContinuation { held = $0 }
            return Transcript(raw: text)
        }
    }

    func cancel() async {
        cancels += 1
    }

    func release() {
        held?.resume()
        held = nil
    }

    func waitForCalls(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }
}

/// Lets the loop run whatever it can without the clock moving, before a test checks that nothing happened.
private func settle() async {
    for _ in 0..<100 { await Task.yield() }
}

@Suite("PartialTranscription")
struct PartialTranscriptionTests {
    private let clock = ManualClock()

    @Test("no decode before 3 s")
    func firstDecodeWaitsThreeSeconds() async {
        let engine = FakeEngine()
        let tail = FakeTail()
        let partial = PartialTranscription(engine: engine, tail: tail, clock: clock)
        await partial.start(UtteranceID(1))
        await clock.waitForSleeps(1)
        clock.advance(by: .milliseconds(2_999))
        await settle()
        #expect(await engine.calls == 0)
        #expect(tail.takes == 0)
        clock.advance(by: .milliseconds(1))
        await clock.waitForSleeps(2)
        #expect(await engine.calls == 1)
        await partial.stop()
    }

    @Test("the cadence waits for the previous decode to return")
    func cadenceWaitsForHeldDecode() async {
        let engine = FakeEngine([.held("first")])
        let partial = PartialTranscription(engine: engine, tail: FakeTail(), clock: clock)
        await partial.start(UtteranceID(1))
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(3))
        await engine.waitForCalls(1)
        clock.advance(by: .seconds(10))
        await settle()
        #expect(await engine.calls == 1)
        #expect(clock.sleeperCount == 0)
        await engine.release()
        await clock.waitForSleeps(2)
        clock.advance(by: .milliseconds(1_499))
        await settle()
        #expect(await engine.calls == 1)
        clock.advance(by: .milliseconds(1))
        await engine.waitForCalls(2)
        await partial.stop()
    }

    @Test("silence since the last partial skips the decode")
    func silenceSkipsDecode() async {
        let engine = FakeEngine()
        let tail = FakeTail([nil, [0.5]])
        let partial = PartialTranscription(engine: engine, tail: tail, clock: clock)
        await partial.start(UtteranceID(1))
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(3))
        await clock.waitForSleeps(2)
        #expect(tail.takes == 1)
        #expect(await engine.calls == 0)
        clock.advance(by: .milliseconds(1_500))
        await clock.waitForSleeps(3)
        #expect(tail.takes == 2)
        #expect(await engine.calls == 1)
        await partial.stop()
    }
}

extension PartialTranscriptionTests {
    @Test("a blank or failed decode yields nothing and the next try keeps the cadence")
    func blankAndFailedYieldNothing() async {
        let engine = FakeEngine([.text("  \n"), .fail, .text("  bonjour  ")])
        let partial = PartialTranscription(engine: engine, tail: FakeTail(), clock: clock)
        var results = partial.results.makeAsyncIterator()
        await partial.start(UtteranceID(7))
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(3))
        await clock.waitForSleeps(2)
        #expect(await engine.calls == 1)
        clock.advance(by: .milliseconds(1_499))
        await settle()
        #expect(await engine.calls == 1)
        clock.advance(by: .milliseconds(1))
        await clock.waitForSleeps(3)
        #expect(await engine.calls == 2)
        clock.advance(by: .milliseconds(1_500))
        await clock.waitForSleeps(4)
        #expect(await engine.calls == 3)
        #expect(await results.next() == PartialTranscription.Result(utterance: UtteranceID(7), text: "bonjour"))
        await partial.stop()
    }

    @Test("stop cancels the engine once and no decode starts after it")
    func stopCancelsOnce() async {
        let engine = FakeEngine()
        let partial = PartialTranscription(engine: engine, tail: FakeTail(), clock: clock)
        await partial.start(UtteranceID(1))
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(3))
        await clock.waitForSleeps(2)
        await partial.stop()
        await partial.stop()
        #expect(await engine.cancels == 1)
        clock.advance(by: .seconds(10))
        await settle()
        #expect(await engine.calls == 1)
    }

    @Test("a loop cancelled between the tail and the decode starts no decode")
    func cancelAfterTakeStartsNoDecode() async {
        let engine = FakeEngine()
        // Cancels the loop's own task from inside the take, as a stop landing right after it would.
        let tail = FakeTail(onTake: { withUnsafeCurrentTask { $0?.cancel() } })
        let partial = PartialTranscription(engine: engine, tail: tail, clock: clock)
        await partial.start(UtteranceID(1))
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(3))
        await settle()
        #expect(tail.takes == 1)
        #expect(await engine.calls == 0)
        #expect(clock.sleeperCount == 0)
        await partial.stop()
    }

    @Test("stop with no loop starts nothing and cancels nothing")
    func stopWithoutLoop() async {
        let engine = FakeEngine()
        let tail = FakeTail()
        let partial = PartialTranscription(engine: engine, tail: tail, clock: clock)
        await partial.stop()
        clock.advance(by: .seconds(10))
        await settle()
        #expect(await engine.cancels == 0)
        #expect(await engine.calls == 0)
        #expect(tail.takes == 0)
    }

    @Test("a new utterance's first decode waits for the previous one's last call")
    func newUtteranceWaitsForPreviousDecode() async {
        let engine = FakeEngine([.held("old"), .text("new")])
        let partial = PartialTranscription(engine: engine, tail: FakeTail(), clock: clock)
        var results = partial.results.makeAsyncIterator()
        await partial.start(UtteranceID(1))
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(3))
        await engine.waitForCalls(1)
        await partial.start(UtteranceID(2))
        #expect(await engine.cancels == 1)
        await clock.waitForSleeps(2)
        clock.advance(by: .seconds(3))
        await settle()
        #expect(await engine.calls == 1)
        await engine.release()
        await engine.waitForCalls(2)
        #expect(await results.next() == PartialTranscription.Result(utterance: UtteranceID(2), text: "new"))
        await partial.stop()
    }

    @Test("starting the utterance already running changes nothing")
    func restartSameUtterance() async {
        let engine = FakeEngine()
        let partial = PartialTranscription(engine: engine, tail: FakeTail(), clock: clock)
        await partial.start(UtteranceID(3))
        await partial.start(UtteranceID(3))
        await clock.waitForSleeps(1)
        await settle()
        #expect(clock.sleeperCount == 1)
        #expect(await engine.cancels == 0)
        await partial.stop()
    }
}

@Suite("PartialLine")
struct PartialLineTests {
    private static func snapshot(_ phase: PipelinePhase, _ id: UInt64?) -> PipelineSnapshot {
        guard let id else { return PipelineSnapshot(phase: phase) }
        let context = UtteranceContext(id: UtteranceID(id), pressedAt: Date(timeIntervalSince1970: 0))
        return PipelineSnapshot(phase: phase, utterance: context)
    }

    private static func result(_ id: UInt64, _ text: String) -> PartialTranscription.Result {
        PartialTranscription.Result(utterance: UtteranceID(id), text: text)
    }

    /// A line showing "first" for utterance 1, captured with the setting on.
    private static func showingFirst() -> PartialLine {
        var line = PartialLine()
        line.accept(result(1, "first"), snapshot: snapshot(.capturing, 1), enabled: true)
        return line
    }

    @Test("a result for the utterance being captured is shown, whitespace collapsed")
    func currentResultShown() {
        var line = PartialLine()
        let took = line.accept(
            Self.result(1, "  ouvre \n  Slack "), snapshot: Self.snapshot(.capturing, 1), enabled: true)
        #expect(took)
        #expect(line.text == "ouvre Slack")
    }

    @Test("a new utterance starts with no line")
    func newUtteranceClears() {
        var line = Self.showingFirst()
        line.follow(Self.snapshot(.idle, nil), enabled: true)
        line.follow(Self.snapshot(.capturing, 2), enabled: true)
        #expect(line.text == nil)
    }

    @Test("a result of the first utterance delivered after the second is armed is dropped")
    func staleUtteranceDropped() {
        var line = Self.showingFirst()
        let took = line.accept(Self.result(1, "late"), snapshot: Self.snapshot(.capturing, 2), enabled: true)
        #expect(!took)
        #expect(line.text == nil)
    }

    @Test(
        "a result after the phase left capturing is dropped and the line stays",
        arguments: [
            PipelinePhase.transcribing, .resolving, .inserting, .idle,
        ])
    func afterCaptureDropped(phase: PipelinePhase) {
        var line = Self.showingFirst()
        let snapshot = Self.snapshot(phase, phase == .idle ? nil : 1)
        let took = line.accept(Self.result(1, "late"), snapshot: snapshot, enabled: true)
        #expect(!took)
        #expect(line.text == "first")
    }

    @Test("the setting off clears the line and drops results")
    func settingOffClears() {
        var line = Self.showingFirst()
        line.follow(Self.snapshot(.capturing, 1), enabled: false)
        #expect(line.text == nil)
        let took = line.accept(Self.result(1, "more"), snapshot: Self.snapshot(.capturing, 1), enabled: false)
        #expect(!took)
        #expect(line.text == nil)
    }

    @Test("a blank result is dropped and the line stays")
    func blankDropped() {
        var line = Self.showingFirst()
        let took = line.accept(Self.result(1, " \n "), snapshot: Self.snapshot(.capturing, 1), enabled: true)
        #expect(!took)
        #expect(line.text == "first")
    }

    @Test("the same utterance keeps its line across snapshots")
    func sameUtteranceKeeps() {
        var line = Self.showingFirst()
        line.follow(Self.snapshot(.capturing, 1), enabled: true)
        #expect(line.text == "first")
    }
}
