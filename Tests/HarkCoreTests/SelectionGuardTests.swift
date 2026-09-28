import Foundation
import HarkCore
import Testing

private typealias F = Fixture

struct GuardCase: Sendable, CustomTestStringConvertible {
    let name: String
    let caller: AppIdentity?
    let frontmost: AppIdentity?
    let live: String?
    let verdict: SelectionVerdict

    var testDescription: String { name }
}

private let text = "Le comité se réunira jeudi.\nMerci."

@Suite struct SelectionGuardTests {
    static let cases: [GuardCase] = [
        .init(name: "same app, same text", caller: F.textEdit, frontmost: F.textEdit, live: text, verdict: .intact),
        .init(
            name: "same app, CRLF against LF", caller: F.textEdit, frontmost: F.textEdit,
            live: text.replacingOccurrences(of: "\n", with: "\r\n"), verdict: .intact),
        .init(
            name: "same app, unreadable: the app check alone", caller: F.textEdit, frontmost: F.textEdit, live: nil,
            verdict: .intact),
        .init(
            name: "same app, another selection", caller: F.textEdit, frontmost: F.textEdit, live: "Le comité",
            verdict: .changed),
        .init(
            name: "same app, only a caret left", caller: F.textEdit, frontmost: F.textEdit, live: "",
            verdict: .changed),
        .init(
            name: "same app, trailing space added", caller: F.textEdit, frontmost: F.textEdit, live: text + " ",
            verdict: .changed),
        .init(name: "another app", caller: F.textEdit, frontmost: F.mail, live: text, verdict: .otherApp),
        .init(name: "nothing in front", caller: F.textEdit, frontmost: nil, live: nil, verdict: .otherApp),
        .init(name: "caller unknown", caller: nil, frontmost: F.textEdit, live: text, verdict: .otherApp),
        .init(
            name: "same name, another process", caller: F.textEdit,
            frontmost: AppIdentity(bundleID: "com.apple.TextEdit", name: "TextEdit", processID: 999), live: text,
            verdict: .otherApp),
    ]

    @Test(arguments: cases)
    func verdict(_ row: GuardCase) {
        let selection = SelectionSnapshot(text: text, caller: row.caller)
        #expect(SelectionGuard.verdict(selection, frontmost: row.frontmost, liveSelection: row.live) == row.verdict)
    }

    private func checker(
        front: AppIdentity?, element: FocusedElement? = F.backInTextEdit.element, selected: String?
    ) -> CallerSelectionChecker {
        let workspace = SwitchableWorkspace(front)
        let accessibility = FakeAccessibility()
        if let element, let pid = front?.processID { accessibility.set(element: element, for: pid) }
        if let pid = front?.processID { accessibility.set(selectedText: selected, for: pid) }
        return CallerSelectionChecker(
            workspace: workspace, focus: AXFocusProbe(workspace: workspace, accessibility: accessibility),
            accessibility: accessibility, settings: ResolutionSettings())
    }

    @Test func anIntactSelectionInATextViewGetsAnAXInsertion() async {
        let check = await checker(front: F.textEdit, selected: text).check(
            SelectionSnapshot(text: text, caller: F.textEdit))
        #expect(check.verdict == .intact && check.plan == .axInsert && check.focus.app == F.textEdit)
    }

    /// Clipboard-only mode is the user's default for dictation; Replace is a request for this field.
    @Test func clipboardOnlyModeDoesNotStopAReplace() async {
        let workspace = SwitchableWorkspace(F.textEdit)
        let accessibility = FakeAccessibility()
        accessibility.set(element: F.backInTextEdit.element, for: F.textEdit.processID)
        let settings = ResolutionSettings(.init(insertionMode: .clipboard))
        let check = await CallerSelectionChecker(
            workspace: workspace, focus: AXFocusProbe(workspace: workspace, accessibility: accessibility),
            accessibility: accessibility, settings: settings
        ).check(SelectionSnapshot(text: text, caller: F.textEdit))
        #expect(check.verdict == .intact && check.plan == .axInsert)
    }

    @Test func aChangedSelectionHasNoPlan() async {
        let check = await checker(front: F.textEdit, selected: "autre").check(
            SelectionSnapshot(text: text, caller: F.textEdit))
        #expect(check.verdict == .changed && check.plan == nil)
    }

    /// The selection of an app that is not the caller is never read.
    @Test func anotherAppInFrontIsNotRead() async {
        let check = await checker(front: F.mail, selected: text).check(
            SelectionSnapshot(text: text, caller: F.textEdit))
        #expect(check.verdict == .otherApp && check.plan == nil)
    }
}
