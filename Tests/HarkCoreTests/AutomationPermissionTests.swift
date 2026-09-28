import ApplicationServices
import HarkCore
import Testing

@Suite struct AutomationPermissionTests {
    /// The numbers, not the SDK constants, so the table pins what `AEDeterminePermissionToAutomateTarget` returns.
    @Test(
        arguments: [
            (0, AutomationStatus.granted),
            (-1743, .denied),
            (-1744, .notDetermined),
            (-600, .targetNotRunning),
            (-1712, .unknown(-1712)),
            (-50, .unknown(-50)),
            (1, .unknown(1)),
        ] as [(OSStatus, AutomationStatus)])
    func status(_ result: OSStatus, _ expected: AutomationStatus) {
        #expect(AutomationPermission.status(for: result) == expected)
    }
}
