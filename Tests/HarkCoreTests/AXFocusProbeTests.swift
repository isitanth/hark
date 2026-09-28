import Foundation
import HarkCore
import Testing

private typealias F = Fixture

@Suite struct AXFocusProbeTests {
    private let accessibility = FakeAccessibility()

    private func probe(frontmost: AppIdentity? = F.mail) async -> FocusSnapshot {
        await AXFocusProbe(workspace: SwitchableWorkspace(frontmost), accessibility: accessibility).probe()
    }

    @Test func theFrontmostAppsFocusedElementIsTaken() async {
        let element = FocusedElement(role: "AXTextArea", acceptsSelectedText: true, valueSettable: true)
        accessibility.set(element: element, for: F.mail.processID)

        let snapshot = await probe()

        #expect(snapshot == FocusSnapshot(app: F.mail, element: element, isSecureInput: false))
    }

    @Test func anAppThatDoesNotAnswerHasNoElement() async {
        let snapshot = await probe()
        #expect(snapshot.app == F.mail && snapshot.element == nil && !snapshot.isSecureInput)
    }

    @Test func aSecureTextFieldIsSecureInputWithoutTheGlobalFlag() async {
        let field = FocusedElement(role: "AXTextField", subrole: FocusedElement.secureTextFieldSubrole)
        accessibility.set(element: field, for: F.mail.processID)

        #expect(await probe().isSecureInput)
    }

    @Test func secureEventInputHeldAnywhereIsSecureInput() async {
        accessibility.set(element: FocusedElement(role: "AXTextArea", acceptsSelectedText: true), for: 501)
        accessibility.set(secureInput: true)

        #expect(await probe().isSecureInput)
        #expect(await probe(frontmost: nil) == FocusSnapshot(app: nil, isSecureInput: true))
    }

    @Test func noFrontmostAppIsAnEmptySnapshot() async {
        #expect(await probe(frontmost: nil) == FocusSnapshot(app: nil))
    }
}
