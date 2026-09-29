import Foundation
import HarkCore
import Testing
import os

private typealias F = Fixture

/// A copier that says what the test tells it, and counts the ⌘C it would have sent.
private final class ScriptedCopier: SelectionCopying {
    private let copies = OSAllocatedUnfairLock(initialState: 0)
    let text: String?

    init(_ text: String?) { self.text = text }

    var count: Int { copies.withLock { $0 } }

    func copySelection(from target: AppIdentity) async -> String? {
        copies.withLock { $0 += 1 }
        return text
    }
}

/// M9.0's rule for the Ask key: Accessibility first; ⌘C only where it says nothing, never into secure input.
@Suite struct SelectionReaderTests {
    @Test func accessibilityAnswersAndNothingIsCopied() async {
        let accessibility = FakeAccessibility()
        accessibility.set(selectedText: "le comité", for: F.textEdit.processID)
        let copier = ScriptedCopier("other")
        let snapshot = await SelectionReader(accessibility: accessibility, copier: copier).read(from: F.textEdit)
        #expect(snapshot == SelectionSnapshot(text: "le comité", caller: F.textEdit))
        #expect(copier.count == 0)
    }

    /// An empty answer is a caret: the assistant, with no ⌘C sent into the field.
    @Test func aCaretIsNothingSelected() async {
        let accessibility = FakeAccessibility()
        accessibility.set(selectedText: "", for: F.textEdit.processID)
        let copier = ScriptedCopier("line")
        let snapshot = await SelectionReader(accessibility: accessibility, copier: copier).read(from: F.textEdit)
        #expect(snapshot.isBlank && snapshot.caller == F.textEdit && copier.count == 0)
    }

    @Test func noAnswerIsCopied() async {
        let copier = ScriptedCopier("page text")
        let snapshot = await SelectionReader(accessibility: FakeAccessibility(), copier: copier).read(from: F.mail)
        #expect(snapshot == SelectionSnapshot(text: "page text", caller: F.mail))
        #expect(copier.count == 1)
    }

    @Test func noAnswerAndNothingCopiedIsTheAssistant() async {
        let snapshot = await SelectionReader(accessibility: FakeAccessibility(), copier: ScriptedCopier(nil))
            .read(from: F.mail)
        #expect(snapshot.isBlank && snapshot.caller == F.mail)
    }

    @Test func secureInputIsNeverCopied() async {
        let accessibility = FakeAccessibility()
        accessibility.set(secureInput: true)
        let copier = ScriptedCopier("hunter2")
        let snapshot = await SelectionReader(accessibility: accessibility, copier: copier).read(from: F.mail)
        #expect(snapshot.isBlank && copier.count == 0)
    }

    /// VS Code copies the current line on ⌘C with nothing selected: no copy is sent there.
    @Test(arguments: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.jetbrains.intellij"])
    func anEditorThatCopiesTheLineGetsNoCopy(_ bundleID: String) async {
        let copier = ScriptedCopier("let x = 1\n")
        let editor = AppIdentity(bundleID: bundleID, name: "Editor", processID: 700, embedsChromium: true)
        let snapshot = await SelectionReader(accessibility: FakeAccessibility(), copier: copier).read(from: editor)
        #expect(snapshot.isBlank && snapshot.caller == editor && copier.count == 0)
    }

    /// Hark's own window in front: nothing is read from Hark itself, as the Ask key does.
    @Test func harkItselfIsNeverRead() async {
        let accessibility = FakeAccessibility()
        let pid = ProcessInfo.processInfo.processIdentifier
        accessibility.set(selectedText: "réglages", for: pid)
        let copier = ScriptedCopier("x")
        let hark = AppIdentity(bundleID: "com.anthonychambet.hark", name: "Hark", processID: pid)
        let snapshot = await SelectionReader(accessibility: accessibility, copier: copier).read(from: hark)
        #expect(snapshot == SelectionSnapshot(text: "", caller: nil) && copier.count == 0)
    }

    @Test func noAppIsNothingSelected() async {
        let copier = ScriptedCopier("x")
        let snapshot = await SelectionReader(accessibility: FakeAccessibility(), copier: copier).read(from: nil)
        #expect(snapshot == SelectionSnapshot(text: "", caller: nil) && copier.count == 0)
    }
}

/// The ⌘C itself: what it copies, and that the user's clipboard is what is left afterwards.
@Suite(.timeLimit(.minutes(1)))
struct SelectionCopyTests {
    private struct Rig {
        let accessibility = FakeAccessibility()
        let pasteboard = FakePasteboard(text: "original")
        let keystrokes: FakeKeystrokes
        let workspace = SwitchableWorkspace(F.mail)
        let clock = ManualClock()
        let inserter: TextInserter

        init(copyDeadline: Duration = .zero) {
            keystrokes = FakeKeystrokes(target: pasteboard)
            inserter = TextInserter(
                accessibility: accessibility, pasteboard: pasteboard, keystrokes: keystrokes, workspace: workspace,
                clock: clock, copyDeadline: copyDeadline)
        }
    }

    @Test func theSelectionIsCopiedAndTheClipboardComesBack() async {
        let rig = Rig()
        let before = await rig.pasteboard.snapshot()
        rig.keystrokes.select("renard brun saute par")
        #expect(await rig.inserter.copySelection(from: F.mail) == "renard brun saute par")
        #expect(rig.keystrokes.posted == [.copy])
        #expect(rig.pasteboard.items == before.items && rig.pasteboard.restores == 1)
    }

    /// With nothing selected the count never moves: nothing is copied and the clipboard is not touched.
    @Test func nothingSelectedCopiesNothing() async {
        let rig = Rig()
        #expect(await rig.inserter.copySelection(from: F.mail) == nil)
        #expect(rig.keystrokes.posted == [.copy])
        #expect(rig.pasteboard.text == "original" && rig.pasteboard.restoreAttempts == 0)
    }

    @Test func anotherAppInFrontGetsNoKeystroke() async {
        let rig = Rig()
        rig.keystrokes.select("x")
        #expect(await rig.inserter.copySelection(from: F.textEdit) == nil)
        #expect(rig.keystrokes.posted.isEmpty)
    }

    @Test func withoutTrustNothingIsSent() async {
        let rig = Rig()
        rig.accessibility.set(trusted: false)
        rig.keystrokes.select("x")
        #expect(await rig.inserter.copySelection(from: F.mail) == nil)
        #expect(rig.keystrokes.posted.isEmpty)
    }

    /// The app copies after the deadline: the watch puts the user's contents back over it.
    @Test func aLateCopyIsPutBack() async {
        let rig = Rig()
        #expect(await rig.inserter.copySelection(from: F.mail) == nil)
        rig.pasteboard.userCopies("late selection")
        await rig.clock.waitForSleeps(1)
        rig.clock.advance(by: .milliseconds(20))
        await eventually { rig.pasteboard.text == "original" }
        #expect(rig.pasteboard.text == "original")
    }

    /// The app writes a second time after the restore, its rich types after its text: put back again.
    @Test func aSecondWriteIsPutBack() async {
        let rig = Rig()
        rig.keystrokes.select("sélection")
        #expect(await rig.inserter.copySelection(from: F.mail) == "sélection")
        rig.pasteboard.userCopies("sélection, en HTML")
        await rig.clock.waitForSleeps(1)
        rig.clock.advance(by: .milliseconds(20))
        await eventually { rig.pasteboard.text == "original" }
        #expect(rig.pasteboard.text == "original" && rig.pasteboard.restores == 2)
    }

    /// Hark's own Copy right after the ⌘C: the watch stops, and Hark's text stays.
    @Test func harksOwnCopyEndsTheWatch() async {
        let rig = Rig()
        rig.keystrokes.select("sélection")
        #expect(await rig.inserter.copySelection(from: F.mail) == "sélection")
        await rig.inserter.releasePasteboard()
        rig.pasteboard.userCopies("Lima.")
        rig.clock.advance(by: .seconds(2))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.pasteboard.text == "Lima.")
    }

    /// A dictation pasted just before, its restore still pending: the user's contents come back, not the dictation.
    @Test func aPendingRestoreGivesBackTheUsersContents() async throws {
        let rig = Rig()
        try await rig.inserter.insert("dictée", plan: .paste, focus: F.focus, clipboardFallback: true)
        #expect(rig.pasteboard.text == "dictée")
        rig.keystrokes.select("sélection")
        #expect(await rig.inserter.copySelection(from: F.mail) == "sélection")
        #expect(rig.pasteboard.text == "original")
    }

    /// Nothing selected right after a paste: the dictation still goes, and the user's contents come back.
    @Test func aPendingRestoreStillEndsWhenNothingIsCopied() async throws {
        let rig = Rig()
        try await rig.inserter.insert("dictée", plan: .paste, focus: F.focus, clipboardFallback: true)
        #expect(await rig.inserter.copySelection(from: F.mail) == nil)
        #expect(rig.pasteboard.text == "original")
    }
}
