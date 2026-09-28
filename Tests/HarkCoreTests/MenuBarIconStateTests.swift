import HarkCore
import Testing

@Suite struct MenuBarIconStateTests {
    @Test(arguments: [
        (PipelinePhase.idle, false, false, MenuBarIconState.idle),
        (.idle, true, false, .armed),
        (.idle, false, true, .error),
        (.idle, true, true, .error),
        (.capturing, false, true, .recording),
        (.capturing, true, false, .recording),
        (.transcribing, false, true, .transcribing),
        (.resolving, false, false, .transcribing),
        (.confirming, false, false, .transcribing),
        (.acting, false, false, .transcribing),
        (.inserting, false, false, .transcribing),
        (.copying, false, false, .transcribing),
    ])
    func state(_ phase: PipelinePhase, _ armed: Bool, _ error: Bool, _ expected: MenuBarIconState) {
        #expect(MenuBarIconState(phase: phase, isArmed: armed, hasError: error) == expected)
    }
}
