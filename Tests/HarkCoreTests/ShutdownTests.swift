import Foundation
import HarkCore
import Testing
import os

/// Opens when the test says, for work that stands for a decode or an unload that cannot be hurried.
private final class Gate: Sendable {
    private let state = OSAllocatedUnfairLock(
        initialState: (open: false, waiters: [CheckedContinuation<Void, Never>]()))

    func wait() async {
        await withCheckedContinuation { continuation in
            let open = state.withLock { state -> Bool in
                if !state.open { state.waiters.append(continuation) }
                return state.open
            }
            if open { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Records what happens to it; its unload can be held.
private final class RecordingEngine: TranscriptionEngine {
    let name: String
    let unloadGate: Gate?
    private let log: OSAllocatedUnfairLock<[String]>

    init(_ name: String, log: OSAllocatedUnfairLock<[String]>, unloadGate: Gate? = nil) {
        self.name = name
        self.log = log
        self.unloadGate = unloadGate
    }

    func transcribe(_ samples: [Float]) async throws(PipelineFailure) -> Transcript {
        Transcript(raw: name, tier: .small)
    }

    func cancel() async { log.withLock { $0.append("\(name).cancel") } }

    func unload() async {
        await unloadGate?.wait()
        log.withLock { $0.append("\(name).unload") }
    }

    func shutdown() async {
        await unload()
        log.withLock { $0.append("\(name).shutdown") }
    }
}

@Suite struct DeadlineTests {
    @Test func workThatFinishesFirstGivesItsResult() async {
        #expect(await Deadline.first(of: { 42 }, within: .seconds(5), clock: ManualClock()) == 42)
    }

    /// A task group would wait for the work; this returns at the deadline and leaves the work running.
    @Test func theDeadlineDoesNotWaitForTheWork() async {
        let clock = ManualClock()
        let gate = Gate()
        async let result = Deadline.first(
            of: {
                await gate.wait()
                return 1
            }, within: .seconds(3), clock: clock)
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(3))
        #expect(await result == nil)
        gate.open()
    }
}

@Suite struct EngineShutdownTests {
    @Test func afterShutdownNothingDecodes() async {
        let log = OSAllocatedUnfairLock(initialState: [String]())
        let engine = SwappableTranscriptionEngine(RecordingEngine("small", log: log))
        await engine.shutdown()
        await #expect(throws: PipelineFailure.quitting) { try await engine.transcribe([0]) }
        #expect(log.withLock { $0 } == ["small.cancel", "small.unload", "small.shutdown"])
    }

    /// A model picked, or loaded at launch, while the app quits must not bring a context back.
    @Test func aSwapAfterShutdownShutsTheNewEngineDownAndKeepsNone() async {
        let log = OSAllocatedUnfairLock(initialState: [String]())
        let engine = SwappableTranscriptionEngine(RecordingEngine("small", log: log))
        await engine.shutdown()
        await engine.replace(with: RecordingEngine("medium", log: log))
        #expect(log.withLock { $0 }.suffix(2) == ["medium.unload", "medium.shutdown"])
        await #expect(throws: PipelineFailure.quitting) { try await engine.transcribe([0]) }
    }

    /// The engine replaced a moment before quitting is still unloading behind its decode; quitting waits for it.
    @Test func shutdownWaitsForAnEngineStillBeingRetired() async {
        let log = OSAllocatedUnfairLock(initialState: [String]())
        let held = Gate()
        let engine = SwappableTranscriptionEngine(RecordingEngine("small", log: log, unloadGate: held))
        let swap = Task { await engine.replace(with: RecordingEngine("medium", log: log)) }
        while !(await engine.isRetiring) { await Task.yield() }
        let quit = Task { await engine.shutdown() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!log.withLock { $0 }.contains("small.shutdown"))
        held.open()
        await swap.value
        await quit.value
        #expect(log.withLock { $0 }.contains("small.shutdown"))
        #expect(log.withLock { $0 }.contains("medium.shutdown"))
    }

    /// The whisper engine itself refuses to load once shut down, whatever asks: a warm-up or a press.
    @Test func aShutDownTranscriberNeverLoads() async {
        let model = ModelInstallation(tier: .small, weights: URL(filePath: "/nonexistent/ggml-small-q8_0.bin"))
        let transcriber = Transcriber(model: model, language: .auto)
        await transcriber.shutdown()
        await #expect(throws: PipelineFailure.quitting) { try await transcriber.prepare() }
        await #expect(throws: PipelineFailure.quitting) { try await transcriber.transcribe([0]) }
        #expect(await !transcriber.isLoaded())
    }
}
