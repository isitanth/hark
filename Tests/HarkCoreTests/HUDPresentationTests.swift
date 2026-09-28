import Foundation
import HarkCore
import Testing

/// One point of the HUD's input space: the phase, whether the key came up, the capture's summary, the last level and
/// the latch.
struct HUDCase: Sendable, CustomTestStringConvertible {
    let phase: PipelinePhase
    let released: Bool
    let capture: CaptureSummary?
    let lastLevel: LevelReading?
    let handsFree: Bool

    var testDescription: String {
        let captureText = capture.map { "\($0.durationMs) ms\($0.reachedMaxDuration ? " at the limit" : "")" } ?? "nil"
        let levelText = lastLevel.map { "\($0.durationMs) ms" } ?? "nil"
        return "\(phase), released \(released), capture \(captureText), level \(levelText), handsFree \(handsFree)"
    }

    var snapshot: PipelineSnapshot {
        guard phase != .idle else { return PipelineSnapshot(phase: .idle) }
        var context = UtteranceContext(id: UtteranceID(1), pressedAt: Date(timeIntervalSince1970: 0))
        if released { context.releasedAt = Date(timeIntervalSince1970: 60) }
        context.capture = capture
        return PipelineSnapshot(phase: phase, utterance: context)
    }

    /// Plan 2.4's table, written from the table rather than from the implementation.
    var expected: HUDState {
        switch phase {
        case .capturing:
            return .listening(handsFree: handsFree)
        case .transcribing:
            if !released { return .transcribing(.limitReached) }
            if let capture { return capture.durationMs > 30_000 ? .transcribing(.longClip) : .hidden }
            if let lastLevel, lastLevel.durationMs > 30_000 { return .transcribing(.longClip) }
            return .hidden
        case .idle, .resolving, .confirming, .acting, .inserting, .copying, .asking:
            return .hidden
        }
    }
}

let hudCases: [HUDCase] = {
    let captures: [CaptureSummary?] = [
        nil,
        CaptureSummary(durationMs: 30_000, peakRMS: 0.2, meanRMS: 0.05),
        CaptureSummary(durationMs: 30_001, peakRMS: 0.2, meanRMS: 0.05),
        CaptureSummary(durationMs: 1_800_000, peakRMS: 0.2, meanRMS: 0.05, reachedMaxDuration: true),
    ]
    let levels: [LevelReading?] = [
        nil, LevelReading(rms: 0.1, durationMs: 30_000), LevelReading(rms: 0.1, durationMs: 30_001),
    ]
    var cases: [HUDCase] = []
    for phase in PipelinePhase.allCases {
        for released in [false, true] {
            for capture in captures {
                for lastLevel in levels {
                    for handsFree in [false, true] {
                        cases.append(
                            HUDCase(
                                phase: phase, released: released, capture: capture, lastLevel: lastLevel,
                                handsFree: handsFree))
                    }
                }
            }
        }
    }
    return cases
}()

@Suite struct HUDPresentationTests {
    @Test(arguments: hudCases)
    func everyInput(_ hudCase: HUDCase) {
        let state = HUDPresentation.state(hudCase.snapshot, lastLevel: hudCase.lastLevel, handsFree: hudCase.handsFree)
        #expect(state == hudCase.expected, "\(hudCase.testDescription)")
    }

    private func context(released: Bool, captureMs: Int? = nil, atLimit: Bool = false) -> UtteranceContext {
        var context = UtteranceContext(id: UtteranceID(1), pressedAt: Date(timeIntervalSince1970: 0))
        if released { context.releasedAt = Date(timeIntervalSince1970: 1) }
        context.capture = captureMs.map {
            CaptureSummary(durationMs: $0, peakRMS: 0.2, meanRMS: 0.05, reachedMaxDuration: atLimit)
        }
        return context
    }

    @Test func aLatchedCaptureShowsTheLock() {
        let snapshot = PipelineSnapshot(phase: .capturing, utterance: context(released: true))
        #expect(HUDPresentation.state(snapshot, lastLevel: nil, handsFree: true) == .listening(handsFree: true))
    }

    @Test func aHeldCaptureDoesNotShowTheLock() {
        let snapshot = PipelineSnapshot(phase: .capturing, utterance: context(released: false))
        #expect(HUDPresentation.state(snapshot, lastLevel: nil, handsFree: false) == .listening(handsFree: false))
    }

    @Test(arguments: PipelinePhase.allCases.filter { $0 != .capturing })
    func handsFreeIsIgnoredOutsideCapturing(_ phase: PipelinePhase) {
        let snapshot = PipelineSnapshot(phase: phase, utterance: context(released: true))
        #expect(HUDPresentation.state(snapshot, lastLevel: nil, handsFree: true) == .hidden)
    }

    @Test func theLimitWithAShortCaptureIsStillTheLimit() {
        let snapshot = PipelineSnapshot(phase: .transcribing, utterance: context(released: false, captureMs: 5_000))
        let level = LevelReading(rms: 0.1, durationMs: 5_000)
        #expect(HUDPresentation.state(snapshot, lastLevel: level, handsFree: true) == .transcribing(.limitReached))
    }

    @Test func theGapAfterKeyUpOfALongClipShowsTranscribing() {
        let snapshot = PipelineSnapshot(phase: .transcribing, utterance: context(released: true))
        let level = LevelReading(rms: 0.1, durationMs: 45_000)
        #expect(HUDPresentation.state(snapshot, lastLevel: level, handsFree: false) == .transcribing(.longClip))
    }

    @Test func aShortClipAfterKeyUpHides() {
        let snapshot = PipelineSnapshot(phase: .transcribing, utterance: context(released: true))
        let level = LevelReading(rms: 0.1, durationMs: 20_000)
        #expect(HUDPresentation.state(snapshot, lastLevel: level, handsFree: false) == .hidden)
    }

    @Test func transcribingWithoutAnUtteranceHides() {
        let level = LevelReading(rms: 0.1, durationMs: 45_000)
        #expect(
            HUDPresentation.state(PipelineSnapshot(phase: .transcribing), lastLevel: level, handsFree: false) == .hidden
        )
    }
}
