import Foundation
import HarkCore
import Testing
import os

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

    /// The assistant's Insert (M9.1) expects nothing selected: a caret, or an app that does not say.
    static let insertCases: [GuardCase] = [
        .init(name: "insert, a caret", caller: F.textEdit, frontmost: F.textEdit, live: "", verdict: .intact),
        .init(name: "insert, unreadable", caller: F.textEdit, frontmost: F.textEdit, live: nil, verdict: .intact),
        .init(
            name: "insert, text selected since", caller: F.textEdit, frontmost: F.textEdit, live: "jeudi",
            verdict: .changed),
        .init(name: "insert, another app", caller: F.textEdit, frontmost: F.mail, live: "", verdict: .otherApp),
        .init(name: "insert, caller unknown", caller: nil, frontmost: F.textEdit, live: "", verdict: .otherApp),
    ]

    @Test(arguments: insertCases)
    func insertVerdict(_ row: GuardCase) {
        let nothing = SelectionSnapshot(text: "", caller: row.caller)
        #expect(SelectionGuard.verdict(nothing, frontmost: row.frontmost, liveSelection: row.live) == row.verdict)
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

    /// Safari's web view reports no focused element until its window is key again, just after the Ask panel closes.
    @Test func aFocusThatComesBackLateIsWaitedFor() async {
        let workspace = SwitchableWorkspace(F.textEdit)
        let accessibility = FakeAccessibility()
        accessibility.set(selectedText: text, for: F.textEdit.processID)
        let checker = CallerSelectionChecker(
            workspace: workspace, focus: AXFocusProbe(workspace: workspace, accessibility: accessibility),
            accessibility: accessibility, settings: ResolutionSettings(), settle: .seconds(2), poll: .milliseconds(5))
        let check = Task { await checker.check(SelectionSnapshot(text: text, caller: F.textEdit)) }
        try? await Task.sleep(for: .milliseconds(40))
        accessibility.set(element: F.backInTextEdit.element, for: F.textEdit.processID)
        let result = await check.value
        #expect(result.verdict == .intact && result.plan == .axInsert)
    }

    /// An app that never reports a focus is given up on after the settle time: the app check alone, nothing to write in.
    @Test func aFocusThatNeverComesEndsWithNoPlan() async {
        let workspace = SwitchableWorkspace(F.textEdit)
        let accessibility = FakeAccessibility()
        let checker = CallerSelectionChecker(
            workspace: workspace, focus: AXFocusProbe(workspace: workspace, accessibility: accessibility),
            accessibility: accessibility, settings: ResolutionSettings(), settle: .milliseconds(30),
            poll: .milliseconds(5))
        let result = await checker.check(SelectionSnapshot(text: text, caller: F.textEdit))
        #expect(result.verdict == .intact && result.plan == nil)
    }

    /// Where AX says nothing, the check reads the selection with ⌘C, as the press did: text selected since the press
    /// in Dia or Claude is not written over.
    static let silentCases: [(String, String?, String?, SelectionVerdict)] = [
        ("the same text", text, text, .intact),
        ("other text selected since", text, "jeudi", .changed),
        ("nothing selected any more", text, nil, .changed),
        ("insert, still a caret", nil, nil, .intact),
        ("insert, text selected since", nil, "jeudi", .changed),
    ]

    @Test(arguments: silentCases)
    func whereAXIsSilentTheCheckCopies(
        _ name: String, _ expected: String?, _ copied: String?, _ verdict: SelectionVerdict
    )
        async
    {
        let dia = AppIdentity(bundleID: "company.thebrowser.dia", name: "Dia", processID: 640, embedsChromium: true)
        let workspace = SwitchableWorkspace(dia)
        let accessibility = FakeAccessibility()
        accessibility.set(element: FocusedElement(role: "AXTextArea"), for: dia.processID)
        let copier = CheckCopier(copied)
        let check = await CallerSelectionChecker(
            workspace: workspace, focus: AXFocusProbe(workspace: workspace, accessibility: accessibility),
            accessibility: accessibility, copier: copier, settings: ResolutionSettings()
        ).check(SelectionSnapshot(text: expected ?? "", caller: dia))
        #expect(check.verdict == verdict, "\(name)")
        #expect(copier.count == 1)
    }

    /// An editor whose ⌘C copies the whole line gets no copy: the app check alone, as before.
    @Test func anEditorThatCopiesTheLineIsNotCopied() async {
        let code = AppIdentity(bundleID: "com.microsoft.VSCode", name: "Code", processID: 650, embedsChromium: true)
        let workspace = SwitchableWorkspace(code)
        let copier = CheckCopier("let x = 1\n")
        let check = await CallerSelectionChecker(
            workspace: workspace, focus: AXFocusProbe(workspace: workspace, accessibility: FakeAccessibility()),
            accessibility: FakeAccessibility(), copier: copier, settings: ResolutionSettings(), settle: .zero
        ).check(SelectionSnapshot(text: "", caller: code))
        #expect(check.verdict == .intact && copier.count == 0)
    }
}

private final class CheckCopier: SelectionCopying {
    private let copies = OSAllocatedUnfairLock(initialState: 0)
    let text: String?

    init(_ text: String?) { self.text = text }

    var count: Int { copies.withLock { $0 } }

    func copySelection(from target: AppIdentity) async -> String? {
        copies.withLock { $0 += 1 }
        return text
    }
}
