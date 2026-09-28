import Foundation
import HarkCore
import Testing

private typealias F = Fixture

/// The paste path's contract with the user's clipboard: what was there before a paste is there after it, unless the
/// user put something else there in the meantime.
@Suite(.timeLimit(.minutes(1)))
struct PasteboardSnapshotTests {
    private struct Rig {
        let accessibility = FakeAccessibility()
        let pasteboard: FakePasteboard
        let keystrokes: FakeKeystrokes
        let clock = ManualClock()
        let inserter: TextInserter

        init(original: String? = "original") {
            pasteboard = FakePasteboard(text: original)
            keystrokes = FakeKeystrokes(target: pasteboard)
            inserter = TextInserter(
                accessibility: accessibility, pasteboard: pasteboard, keystrokes: keystrokes,
                workspace: SwitchableWorkspace(F.mail), clock: clock)
        }

        func paste(_ text: String, focus: FocusSnapshot = F.focus) async throws {
            try await inserter.insert(text, plan: .paste, focus: focus, clipboardFallback: true)
        }

        /// Lets the restore timer that the `count`th paste started run to the end.
        func elapse(sleeps count: Int = 1) async {
            await clock.waitForSleeps(count)
            clock.advance(by: TextInserter.defaultRestoreDelay)
        }
    }

    @Test func theOriginalContentsComeBackAfterTheDelay() async throws {
        let rig = Rig()
        let before = await rig.pasteboard.snapshot()

        try await rig.paste("hello")

        #expect(rig.pasteboard.text == "hello", "the target app reads the text before the restore")
        #expect(rig.keystrokes.posted == [.paste])
        await rig.elapse()
        await eventually { rig.pasteboard.restoreAttempts == 1 }
        #expect(rig.pasteboard.items == before.items)
        #expect(rig.pasteboard.restores == 1)
    }

    @Test func thePastedTextIsMarkedTransient() async throws {
        let rig = Rig()
        try await rig.paste("hello")
        #expect(rig.pasteboard.writes == [.init(text: "hello", markers: [PasteboardMarker.transient])])
    }

    @Test func secureInputIsAlsoMarkedConcealed() async throws {
        let rig = Rig()
        try await rig.paste("hunter2", focus: FocusSnapshot(app: F.mail, isSecureInput: true))
        #expect(rig.pasteboard.writes.map(\.markers) == [[PasteboardMarker.transient, PasteboardMarker.concealed]])
    }

    @Test func aCopyTheUserMadeMeanwhileIsKept() async throws {
        let rig = Rig()
        try await rig.paste("hello")

        rig.pasteboard.userCopies("mine")
        await rig.elapse()
        await eventually { rig.pasteboard.restoreAttempts == 1 }

        #expect(rig.pasteboard.text == "mine")
        #expect(rig.pasteboard.restores == 0)
    }

    @Test func aSecondPasteBeforeTheRestoreStillRestoresTheUsersContents() async throws {
        let rig = Rig()
        let before = await rig.pasteboard.snapshot()

        try await rig.paste("first")
        await rig.clock.waitForSleeps(1)
        try await rig.paste("second")
        #expect(rig.pasteboard.text == "second")

        await rig.elapse(sleeps: 2)
        await eventually { rig.pasteboard.restoreAttempts >= 1 }
        #expect(rig.pasteboard.items == before.items)
        #expect(rig.pasteboard.restoreAttempts == 1, "the first paste's timer was cancelled")
    }

    @Test func aSecondPasteAfterTheUserCopiedKeepsTheirNewCopy() async throws {
        let rig = Rig()
        try await rig.paste("first")
        await rig.clock.waitForSleeps(1)
        rig.pasteboard.userCopies("mine")
        try await rig.paste("second")

        await rig.elapse(sleeps: 2)
        await eventually { rig.pasteboard.restoreAttempts == 1 }
        #expect(rig.pasteboard.text == "mine")
    }

    @Test func anEmptyPasteboardIsLeftEmpty() async throws {
        let rig = Rig(original: nil)
        try await rig.paste("hello")
        await rig.elapse()
        await eventually { rig.pasteboard.restoreAttempts == 1 }
        #expect(rig.pasteboard.items.isEmpty)
    }

    /// ⌘V into an unfocused web page, or an app too stuck to handle it: nothing reads the promise.
    @Test func aPasteNobodyReadsLeavesTheTextOnTheClipboard() async throws {
        let rig = Rig()
        rig.keystrokes.noAppReads()

        let paste = Task { try await rig.paste("hello") }
        await rig.clock.waitForSleeps(1)
        rig.clock.advance(by: TextInserter.defaultReadDeadline)

        await #expect(throws: PipelineFailure.pasteNotConsumed) { try await paste.value }
        #expect(rig.keystrokes.posted == [.paste])
        #expect(rig.pasteboard.text == "hello", "the text is not taken back from the user")
        #expect(rig.pasteboard.restoreAttempts == 0)
    }

    @Test func aReadJustBeforeTheDeadlineCountsAsAPaste() async throws {
        let rig = Rig()
        rig.keystrokes.noAppReads()

        let paste = Task { try await rig.paste("hello") }
        await rig.clock.waitForSleeps(1)
        rig.clock.advance(by: TextInserter.defaultReadDeadline - .milliseconds(1))
        rig.pasteboard.appReads()

        try await paste.value
        await rig.elapse(sleeps: 2)
        await eventually { rig.pasteboard.restoreAttempts == 1 }
        #expect(rig.pasteboard.text == "original")
    }

    @Test func aKeystrokeTheSystemRefusedRestoresAtOnceAndFails() async {
        let rig = Rig()
        rig.keystrokes.set(accepts: false)

        await #expect(throws: PipelineFailure.insertionFailed) { try await rig.paste("hello") }

        #expect(rig.pasteboard.text == "original")
        #expect(rig.pasteboard.restores == 1)
    }

    @Test func withoutAccessibilityTrustNothingIsWritten() async {
        let rig = Rig()
        rig.accessibility.set(trusted: false)

        await #expect(throws: PipelineFailure.insertionFailed) { try await rig.paste("hello") }

        #expect(rig.pasteboard.writes.isEmpty && rig.keystrokes.posted.isEmpty)
        #expect(rig.pasteboard.text == "original")
    }

    @Test func aFailedWriteIsAPasteboardFailure() async {
        let rig = Rig()
        rig.pasteboard.failNextWrites()

        await #expect(throws: PipelineFailure.pasteboardWrite) { try await rig.paste("hello") }
        #expect(rig.keystrokes.posted.isEmpty)
    }
}
