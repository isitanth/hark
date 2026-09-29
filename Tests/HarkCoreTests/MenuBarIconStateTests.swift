import HarkCore
import Testing

struct IconCase: Sendable, CustomTestStringConvertible {
    let phase: PipelinePhase
    var latched = false
    var armed = false
    var error = false
    var dismissed = false
    let expected: MenuBarIconState

    var testDescription: String {
        "\(phase) latched \(latched) armed \(armed) error \(error) dismissed \(dismissed)"
    }
}

@Suite struct MenuBarIconStateTests {
    @Test(arguments: [
        IconCase(phase: .idle, expected: .idle),
        IconCase(phase: .idle, armed: true, expected: .armed),
        IconCase(phase: .idle, error: true, expected: .error),
        IconCase(phase: .idle, armed: true, error: true, expected: .error),
        IconCase(phase: .idle, error: true, dismissed: true, expected: .dismissed),
        IconCase(phase: .idle, dismissed: true, expected: .dismissed),
        // A latch left over from the last capture shows nothing once the capture is over.
        IconCase(phase: .idle, latched: true, expected: .idle),
        IconCase(phase: .capturing, error: true, expected: .recording),
        IconCase(phase: .capturing, armed: true, expected: .recording),
        IconCase(phase: .capturing, dismissed: true, expected: .recording),
        IconCase(phase: .capturing, latched: true, expected: .handsFree),
        IconCase(phase: .capturing, latched: true, error: true, expected: .handsFree),
        IconCase(phase: .transcribing, error: true, expected: .transcribing),
        IconCase(phase: .transcribing, dismissed: true, expected: .transcribing),
        IconCase(phase: .resolving, expected: .transcribing),
        IconCase(phase: .confirming, expected: .transcribing),
        IconCase(phase: .acting, expected: .transcribing),
        IconCase(phase: .inserting, expected: .transcribing),
        IconCase(phase: .copying, expected: .transcribing),
        IconCase(phase: .asking, expected: .asking),
        IconCase(phase: .asking, latched: true, error: true, dismissed: true, expected: .asking),
    ])
    func state(_ c: IconCase) {
        #expect(
            MenuBarIconState(
                phase: c.phase, isLatched: c.latched, isArmed: c.armed, hasError: c.error, dismissed: c.dismissed)
                == c.expected)
    }

    @Test(arguments: [
        (PipelinePhase.idle, AskStage?.none, false),
        (.capturing, nil, false),
        (.transcribing, nil, true),
        (.resolving, nil, true),
        (.confirming, nil, false),
        (.acting, nil, true),
        (.inserting, nil, true),
        (.copying, nil, true),
        (.asking, .generating, true),
        (.asking, .reviewing, false),
        (.asking, .replacing, false),
        (.asking, .failed(.noAnswer), false),
        (.asking, nil, false),
    ])
    func theBitTurnsWhileHarkWorks(_ phase: PipelinePhase, _ stage: AskStage?, _ working: Bool) {
        let ask = stage.map { AskProgress(instruction: "résume", stage: $0) }
        #expect(MenuBarIconState.isWorking(phase, ask: ask) == working)
    }
}
