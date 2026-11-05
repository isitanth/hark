import Foundation
import HarkCore
import Testing

/// When the layer hides and when the page is still enough to look for the zone again (c3b §2.3), on a test clock.
@Suite struct StillnessDetectorTests {
    private static func ms(_ value: Int) -> Duration { .milliseconds(value) }

    private static func event(_ kind: InputRecord.Kind, _ at: Int) -> InputRecord {
        InputRecord(kind: kind, at: ms(at))
    }

    @Test func nothingHappensBeforeAnyEvent() {
        var detector = StillnessDetector()
        #expect(detector.tick(at: Self.ms(0)) == .none)
        #expect(detector.tick(at: Self.ms(10_000)) == .none)
    }

    @Test(arguments: [
        InputRecord.Kind.scroll(momentumEnded: true), .scroll(momentumEnded: false), .key, .buttonDown,
    ])
    func theFirstEventThatMayMoveThePageHidesOnce(_ kind: InputRecord.Kind) {
        var detector = StillnessDetector()
        #expect(detector.record(Self.event(kind, 0)) == .hide)
        #expect(detector.record(Self.event(kind, 20)) == .none)
        #expect(detector.record(Self.event(.key, 40)) == .none)
    }

    @Test func aButtonUpAloneNeitherHidesNorRecaptures() {
        var detector = StillnessDetector()
        #expect(detector.record(Self.event(.buttonUp, 0)) == .none)
        #expect(detector.tick(at: Self.ms(1_000)) == .none)
    }

    @Test func aWheelRecapturesOnceAfterTheQuietDelay() {
        var detector = StillnessDetector()
        #expect(detector.record(Self.event(.scroll(momentumEnded: true), 0)) == .hide)
        #expect(detector.record(Self.event(.scroll(momentumEnded: true), 30)) == .none)
        #expect(detector.tick(at: Self.ms(279)) == .none)
        #expect(detector.tick(at: Self.ms(280)) == .recapture)
        #expect(detector.tick(at: Self.ms(300)) == .none)
        #expect(detector.tick(at: Self.ms(5_000)) == .none)
    }

    @Test func aLaterEventPushesTheRecaptureBack() {
        var detector = StillnessDetector()
        _ = detector.record(Self.event(.key, 0))
        #expect(detector.tick(at: Self.ms(200)) == .none)
        #expect(detector.record(Self.event(.key, 200)) == .none)
        #expect(detector.tick(at: Self.ms(250)) == .none)
        #expect(detector.tick(at: Self.ms(449)) == .none)
        #expect(detector.tick(at: Self.ms(450)) == .recapture)
    }

    @Test func runningMomentumKeepsItWaiting() {
        var detector = StillnessDetector()
        #expect(detector.record(Self.event(.scroll(momentumEnded: false), 0)) == .hide)
        #expect(detector.tick(at: Self.ms(2_000)) == .none)
        #expect(detector.record(Self.event(.scroll(momentumEnded: true), 2_100)) == .none)
        #expect(detector.tick(at: Self.ms(2_349)) == .none)
        #expect(detector.tick(at: Self.ms(2_350)) == .recapture)
    }

    @Test func aButtonHeldDownKeepsItWaitingAndItsReleaseRestartsTheQuiet() {
        var detector = StillnessDetector()
        #expect(detector.record(Self.event(.buttonDown, 0)) == .hide)
        #expect(detector.tick(at: Self.ms(3_000)) == .none)
        #expect(detector.record(Self.event(.buttonUp, 3_000)) == .none)
        #expect(detector.tick(at: Self.ms(3_249)) == .none)
        #expect(detector.tick(at: Self.ms(3_250)) == .recapture)
    }

    @Test func theNextEventAfterARecaptureHidesAgain() {
        var detector = StillnessDetector()
        _ = detector.record(Self.event(.scroll(momentumEnded: true), 0))
        #expect(detector.tick(at: Self.ms(250)) == .recapture)
        #expect(detector.record(Self.event(.key, 400)) == .hide)
        #expect(detector.tick(at: Self.ms(649)) == .none)
        #expect(detector.tick(at: Self.ms(650)) == .recapture)
    }

    @Test func theQuietDelayIsTheMeasuredOne() {
        #expect(StillnessDetector.quiet == .milliseconds(250))
    }
}
