import Foundation
import HarkCore
import Testing

/// The drill in the menu bar: one form per state, the animations over them, and the second after an utterance.
@Suite struct MenuBarGlyphTests {
    /// The states the menu bar can show; `armed` is never shown.
    static let shown: [MenuBarIconState] = MenuBarIconState.allCases.filter { $0 != .armed }

    @Test func everyShownStateHasAFormOfItsOwn() {
        let glyphs = Self.shown.map { MenuBarGlyph(state: $0) }
        for (index, glyph) in glyphs.enumerated() {
            for other in glyphs[(index + 1)...] {
                #expect(glyph != other, "\(glyph) and \(other)")
            }
        }
    }

    /// The shape says it, never the colour: outline at rest, filled while the microphone is open, the battery alone
    /// while what was said is worked on, a badge for the rest.
    @Test(arguments: [
        (MenuBarIconState.idle, MenuBarGlyph.Fill.outline, MenuBarGlyph.Badge.none, 1.0),
        (.recording, .filled, .none, 1),
        (.handsFree, .filled, .dot, 1),
        (.transcribing, .battery, .none, 0.6),
        (.asking, .outline, .sparkle, 1),
        (.error, .outline, .exclamation, 1),
        (.dismissed, .outline, .cross, 1),
    ])
    func theForms(_ state: MenuBarIconState, _ fill: MenuBarGlyph.Fill, _ badge: MenuBarGlyph.Badge, _ opacity: Double)
    {
        let glyph = MenuBarGlyph(state: state)
        #expect(glyph.fill == fill && glyph.badge == badge && glyph.opacity == opacity)
        #expect(glyph.marks == .none && glyph.rotation == 0 && glyph.dx == 0 && glyph.dy == 0)
    }

    /// Apple's menu bar extras keep at least a point of margin in their canvas; so does every form here.
    @Test(arguments: MenuBarIconState.allCases)
    func everyFormKeepsAPointOfMargin(_ state: MenuBarIconState) {
        let box = MenuBarGlyph(state: state).inkBounds
        #expect(box.minX >= 1 && box.minY >= 1 && box.maxX <= 17 && box.maxY <= 17, "\(box)")
    }

    /// The icon each animation plays over, in the app.
    static let bases: [(MenuBarAnimation, MenuBarIconState)] = [
        (.trigger, .recording), (.trigger, .handsFree), (.spin, .transcribing), (.spin, .asking), (.shake, .dismissed),
    ]

    /// Nothing is ever clipped: at the far end of a move, the ink stays half a point inside the canvas.
    @Test func noFrameLeavesTheCanvas() {
        for (animation, state) in Self.bases {
            for (index, frame) in animation.frames.enumerated() {
                let box = MenuBarGlyph(state: state).applying(frame).inkBounds
                #expect(
                    box.minX >= 0.5 && box.minY >= 0.5 && box.maxX <= 17.5 && box.maxY <= 17.5,
                    "\(animation) frame \(index + 1) over \(state): \(box)")
            }
        }
    }

    /// Every animation ends on the icon of its state, so stopping it early or never starting it (Reduce Motion) leaves
    /// the right icon.
    @Test(arguments: MenuBarAnimation.allCases)
    func everyAnimationEndsAtRest(_ animation: MenuBarAnimation) throws {
        let last = try #require(animation.frames.last)
        #expect(last.isRest)
        for (_, state) in Self.bases {
            let rest = MenuBarGlyph(state: state)
            #expect(rest.applying(last) == rest)
            #expect(rest.applying(nil) == rest)
        }
    }

    @Test(arguments: [
        (MenuBarAnimation.trigger, Duration.milliseconds(330)), (.spin, .milliseconds(430)),
        (.shake, .milliseconds(285)),
    ])
    func everyAnimationIsShort(_ animation: MenuBarAnimation, _ duration: Duration) {
        #expect(animation.duration == duration)
        #expect(animation.duration < .milliseconds(500))
        #expect(animation.frames.allSatisfy { $0.duration >= .milliseconds(30) && $0.duration <= .milliseconds(60) })
    }

    @Test func theSpinRestsBetweenTurns() {
        #expect(MenuBarAnimation.spinPeriod > MenuBarAnimation.spin.duration + .milliseconds(500))
        #expect(MenuBarAnimation.spinDelay == .milliseconds(300))
    }

    /// The trigger turns the nose up and settles; the shake moves the cross with the drill; the spin only adds marks.
    @Test func whatEachAnimationMoves() {
        #expect(MenuBarAnimation.trigger.frames.map(\.rotation).min() == -9)
        #expect(MenuBarAnimation.trigger.frames.allSatisfy { $0.dx == 0 && $0.dy == 0 && $0.marks == .none })
        #expect(MenuBarAnimation.shake.frames.allSatisfy { $0.movesBadge && $0.rotation == 0 && $0.dy == 0 })
        #expect(MenuBarAnimation.spin.frames.allSatisfy { $0.rotation == 0 && $0.dx == 0 && $0.dy == 0 })
        #expect(Set(MenuBarAnimation.spin.frames.map { "\($0.marks)" }).count == 6)
    }

    @Test func aMovingBadgeGoesWithTheDrill() {
        let dismissed = MenuBarGlyph(state: .dismissed)
        #expect(dismissed.fixedParts.count == 1 && !dismissed.movingParts.contains(dismissed.fixedParts[0]))
        let shaken = dismissed.applying(MenuBarAnimation.shake.frames[0])
        #expect(shaken.fixedParts.isEmpty && shaken.movingParts.count == dismissed.movingParts.count + 1)
        #expect(shaken.inkBounds.minX == dismissed.inkBounds.minX - 1)
    }

    @Test(arguments: [
        (Resolution.command, String?.none, MenuBarOutcome?.none),
        (.textInserted, nil, nil),
        (.textClipboard, "no_text_field", nil),
        (.textClipboard, nil, nil),
        (.failed, "llm_unreachable", .failed),
        (.failed, "model_missing:small", .failed),
        (.discarded, "busy", nil),
        (.discarded, "no_speech", .dismissed),
        (.discarded, "too_short", .dismissed),
        (.discarded, "empty_transcript", .dismissed),
        (.discarded, "empty_selection", .dismissed),
        (.discarded, "empty_request", .dismissed),
        (.discarded, "clipboard_fallback_disabled", .dismissed),
        (.discarded, "cancelled", nil),
        (.discarded, "declined", nil),
        (.discarded, "max_duration", nil),
    ])
    func theSecondAfterAnUtterance(_ resolution: Resolution, _ error: String?, _ outcome: MenuBarOutcome?) {
        #expect(MenuBarOutcome(resolution: resolution, error: error) == outcome)
    }
}

/// What a snapshot does to the icon beyond its state.
@Suite struct MenuBarIconUpdateTests {
    static func record(_ outcome: PipelineOutcome) -> UtteranceRecord {
        UtteranceRecord(
            context: UtteranceContext(id: UtteranceID(1), pressedAt: Date(timeIntervalSince1970: 0)), transcript: nil,
            outcome: outcome)
    }

    @Test func aCaptureStartsWithTheTriggerAndClearsTheCross() {
        let update = MenuBarIconUpdate(from: PipelineSnapshot(phase: .idle), to: PipelineSnapshot(phase: .capturing))
        #expect(update == MenuBarIconUpdate(play: .trigger, outcome: .clear))
    }

    @Test func aCaptureThatEndsEndsTheLatch() {
        let update = MenuBarIconUpdate(
            from: PipelineSnapshot(phase: .capturing), to: PipelineSnapshot(phase: .transcribing))
        #expect(update == MenuBarIconUpdate(working: true, endsLatch: true))
    }

    @Test func aFailureShakesAndShowsTheCross() {
        let line = Self.record(.failed(.noInputDevice))
        let update = MenuBarIconUpdate(
            from: PipelineSnapshot(phase: .transcribing), to: PipelineSnapshot(phase: .idle, lastRecord: line))
        #expect(update == MenuBarIconUpdate(play: .shake, outcome: .show(.failed)))
    }

    @Test func nothingHeardShowsTheCrossWithoutAShake() {
        let line = Self.record(.discarded(.noSpeech))
        let update = MenuBarIconUpdate(
            from: PipelineSnapshot(phase: .transcribing), to: PipelineSnapshot(phase: .idle, lastRecord: line))
        #expect(update == MenuBarIconUpdate(outcome: .show(.dismissed)))
    }

    /// A press refused while Hark works says nothing about the utterance in flight, and that utterance's own success
    /// takes away any cross left from before.
    @Test func aBusyPressThenASuccessLeaveNoCross() {
        let busy = Self.record(.discarded(.busy))
        let working = PipelineSnapshot(phase: .transcribing)
        let refused = PipelineSnapshot(phase: .transcribing, lastRecord: busy)
        #expect(MenuBarIconUpdate(from: working, to: refused) == MenuBarIconUpdate(outcome: .clear, working: true))
        let inserted = PipelineSnapshot(phase: .idle, lastRecord: Self.record(.textInserted))
        #expect(MenuBarIconUpdate(from: refused, to: inserted) == MenuBarIconUpdate(outcome: .clear))
    }

    @Test func theSameLineTwiceIsNotANewOne() {
        let line = Self.record(.discarded(.noSpeech))
        let snapshot = PipelineSnapshot(phase: .idle, lastRecord: line)
        #expect(MenuBarIconUpdate(from: snapshot, to: snapshot) == MenuBarIconUpdate())
    }

    @Test func theBitTurnsWhileTheModelWritesOnly() {
        let generating = PipelineSnapshot(
            phase: .asking, ask: AskProgress(instruction: "résume", stage: .generating))
        let reviewing = PipelineSnapshot(phase: .asking, ask: AskProgress(instruction: "résume", stage: .reviewing))
        #expect(MenuBarIconUpdate(from: PipelineSnapshot(phase: .transcribing), to: generating).working)
        #expect(!MenuBarIconUpdate(from: generating, to: reviewing).working)
    }
}
