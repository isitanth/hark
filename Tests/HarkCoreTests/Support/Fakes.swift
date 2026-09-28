import Foundation
import HarkCore
import os

final class ManualWallClock: WallClock {
    private let current: OSAllocatedUnfairLock<Date>

    init(_ start: Date) {
        current = OSAllocatedUnfairLock(initialState: start)
    }

    func now() -> Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0.addTimeInterval(seconds) }
    }
}

/// Returns one second of silence-free samples with the given summary, and emits whatever the test sends. `stopDelay`
/// holds `stop` back, as stopping a real engine does, so an event can land while the stop is in flight.
struct ScriptedAudioInput: AudioInput {
    var summary: CaptureSummary
    var stopDelay: Duration
    let events: AsyncStream<AudioInputEvent>
    private let continuation: AsyncStream<AudioInputEvent>.Continuation

    init(summary: CaptureSummary, stopDelay: Duration = .zero) {
        self.summary = summary
        self.stopDelay = stopDelay
        (events, continuation) = AsyncStream.makeStream()
    }

    func emit(_ event: AudioInputEvent) {
        continuation.yield(event)
    }

    func start(_ id: UtteranceID) async throws(PipelineFailure) {}

    func stop(_ id: UtteranceID) async throws(PipelineFailure) -> CapturedAudio {
        if stopDelay > .zero { try? await Task.sleep(for: stopDelay) }
        return CapturedAudio(summary: summary, samples: [Float](repeating: 0.1, count: 16_000))
    }

    func cancel(_ id: UtteranceID) async {}
}

/// A `@MainActor` seam implementation, shaped like HarkApp's AppKit-backed ones.
@MainActor
final class MainActorWorkspace: Workspace {
    let app: AppIdentity
    private(set) var calls = 0

    init(app: AppIdentity) {
        self.app = app
    }

    func frontmostApplication() async -> AppIdentity? {
        MainActor.preconditionIsolated()
        calls += 1
        return app
    }

    func activate(_ app: AppIdentity) async -> Bool {
        MainActor.preconditionIsolated()
        return true
    }

    func openApplication(at url: URL) async -> ApplicationOpening {
        MainActor.preconditionIsolated()
        return .frontmost
    }
}

struct DiscardingPasteboard: PasteboardFacade {
    func write(_ text: String, markers: Set<String>) async -> Int? { 1 }
    func promise(_ text: String, markers: Set<String>, onRead: @escaping @Sendable () -> Void) async -> Int? { 1 }
    func changeCount() async -> Int { 1 }
    func snapshot() async -> PasteboardSnapshot { PasteboardSnapshot(items: [], changeCount: 1) }
    func restore(_ snapshot: PasteboardSnapshot, ifChangeCountIs expected: Int) async -> Bool { true }
}

/// Hands out its readings in order, then nil as a disarmed capture does.
final class ScriptedLevelSource: AudioLevelSource {
    private let readings: OSAllocatedUnfairLock<[LevelReading]>

    init(_ readings: [LevelReading]) {
        self.readings = OSAllocatedUnfairLock(initialState: readings)
    }

    func takeLevel() -> LevelReading? {
        readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}
