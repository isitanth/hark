import Foundation
import HarkCore
import Testing

/// One key event: how long after the previous one, and whether the pipeline is capturing when it arrives.
struct TriggerStep: Sendable {
    let key: TriggerGate.Key
    let afterMs: Int
    let capturing: Bool

    init(_ key: TriggerGate.Key, afterMs: Int = 0, capturing: Bool = false) {
        self.key = key
        self.afterMs = afterMs
        self.capturing = capturing
    }
}

struct TriggerSequence: Sendable, CustomTestStringConvertible {
    let name: String
    let steps: [TriggerStep]
    let actions: [TriggerGate.Action]

    var testDescription: String { name }
}

let triggerSequences: [TriggerSequence] = [
    .init(
        name: "tap to start, tap again to stop",
        steps: [
            TriggerStep(.down), TriggerStep(.up, afterMs: 80, capturing: true),
            TriggerStep(.down, afterMs: 3_000, capturing: true),
        ],
        actions: [.start, .ignore, .stop]),
    .init(
        name: "hold: stops when the key is let go",
        steps: [TriggerStep(.down), TriggerStep(.up, afterMs: 900, capturing: true)],
        actions: [.start, .stop]),
    .init(
        name: "exactly at the threshold counts as a hold",
        steps: [TriggerStep(.down), TriggerStep(.up, afterMs: 350, capturing: true)],
        actions: [.start, .stop]),
    .init(
        name: "just under the threshold latches",
        steps: [TriggerStep(.down), TriggerStep(.up, afterMs: 349, capturing: true)],
        actions: [.start, .ignore]),
    .init(
        name: "key repeat while holding is ignored",
        steps: [
            TriggerStep(.down), TriggerStep(.down, afterMs: 40, capturing: true),
            TriggerStep(.down, afterMs: 40, capturing: true), TriggerStep(.up, afterMs: 900, capturing: true),
        ],
        actions: [.start, .ignore, .ignore, .stop]),
    .init(
        name: "capture ended on its own: the next tap starts a new one",
        steps: [
            TriggerStep(.down), TriggerStep(.up, afterMs: 80, capturing: true),
            TriggerStep(.down, afterMs: 60_000, capturing: false),
        ],
        actions: [.start, .ignore, .start]),
    .init(
        name: "capture failed while the key is still down",
        steps: [TriggerStep(.down), TriggerStep(.up, afterMs: 900, capturing: false)],
        actions: [.start, .ignore]),
    .init(
        name: "key up with nothing running",
        steps: [TriggerStep(.up), TriggerStep(.up, afterMs: 10)],
        actions: [.ignore, .ignore]),
    .init(
        name: "two taps then a hold",
        steps: [
            TriggerStep(.down), TriggerStep(.up, afterMs: 50, capturing: true),
            TriggerStep(.down, afterMs: 2_000, capturing: true), TriggerStep(.down, afterMs: 1_000, capturing: false),
            TriggerStep(.up, afterMs: 800, capturing: true),
        ],
        actions: [.start, .ignore, .stop, .start, .stop]),
]

@Suite struct TriggerGateTests {
    @Test(arguments: triggerSequences)
    func sequence(_ sequence: TriggerSequence) {
        var gate = TriggerGate()
        var now = ContinuousClock.now
        var actions: [TriggerGate.Action] = []

        for step in sequence.steps {
            now = now.advanced(by: .milliseconds(step.afterMs))
            actions.append(gate.handle(step.key, at: now, isCapturing: step.capturing))
        }

        #expect(actions == sequence.actions)
    }

    @Test func holdThresholdIsConfigurable() {
        var gate = TriggerGate(holdThreshold: .seconds(1))
        let start = ContinuousClock.now
        #expect(gate.handle(.down, at: start, isCapturing: false) == .start)
        #expect(gate.handle(.up, at: start.advanced(by: .milliseconds(400)), isCapturing: true) == .ignore)
        #expect(gate.isLatched)
    }

    @Test func aTapLatchesAndTheNextDownStops() {
        var gate = TriggerGate()
        let start = ContinuousClock.now
        #expect(gate.handle(.down, at: start, isCapturing: false) == .start)
        #expect(!gate.isLatched)
        #expect(gate.handle(.up, at: start.advanced(by: .milliseconds(349)), isCapturing: true) == .ignore)
        #expect(gate.isLatched)
        #expect(gate.handle(.down, at: start.advanced(by: .seconds(5)), isCapturing: true) == .stop)
        #expect(!gate.isLatched)
    }

    @Test func aLatchLeftByACaptureThatEndedOnItsOwnIsGoneAfterTheNextDown() {
        var gate = TriggerGate()
        let start = ContinuousClock.now
        #expect(gate.handle(.down, at: start, isCapturing: false) == .start)
        #expect(gate.handle(.up, at: start.advanced(by: .milliseconds(100)), isCapturing: true) == .ignore)
        #expect(gate.isLatched)
        #expect(gate.handle(.down, at: start.advanced(by: .seconds(1_800)), isCapturing: false) == .start)
        #expect(!gate.isLatched)
    }

    /// An ask's capture starts without the key: latched, the next tap ends it, and its key-up does nothing.
    @Test func aLatchedAskCaptureEndsOnTheNextTap() {
        var gate = TriggerGate()
        let start = ContinuousClock.now
        gate.latch()
        #expect(gate.isLatched)
        #expect(gate.handle(.down, at: start, isCapturing: true) == .stop)
        #expect(gate.handle(.up, at: start.advanced(by: .milliseconds(80)), isCapturing: false) == .ignore)
        #expect(!gate.isLatched)
    }

    /// A latch outlived by its capture (Done in the popup, a cancel) is dropped: the next press starts dictation.
    @Test func aLatchWhoseCaptureEndedStartsAFreshOne() {
        var gate = TriggerGate()
        gate.latch()
        #expect(gate.handle(.down, at: .now, isCapturing: false) == .start)
    }
}
