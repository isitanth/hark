import Foundation
import HarkCore
import Testing

private typealias F = Fixture

/// One press, end to end through the controller, with M4's probe, resolver and inserter on fakes. What the reducer
/// tables cannot show: that the focus the probe saw is the one the inserter acts on, and what the log line says.
@Suite(.timeLimit(.minutes(1)))
struct InsertionPipelineTests {
    private struct StubEngine: TranscriptionEngine {
        let text: String

        func transcribe(_ samples: [Float]) async throws(PipelineFailure) -> Transcript {
            Transcript(raw: text, tier: .small)
        }

        func cancel() async {}
    }

    private struct Rig {
        let directory: TemporaryDirectory
        let workspace: SwitchableWorkspace
        let accessibility = FakeAccessibility()
        let pasteboard: FakePasteboard
        let keystrokes: FakeKeystrokes
        let settings = ResolutionSettings()
        let clock = ManualClock()
        let controller: PipelineController

        init(frontmost: AppIdentity, text: String = "Hello there.", focus: (any FocusProbing)? = nil) throws {
            directory = try TemporaryDirectory()
            workspace = SwitchableWorkspace(frontmost)
            pasteboard = FakePasteboard()
            keystrokes = FakeKeystrokes(target: pasteboard)
            let inserter = TextInserter(
                accessibility: accessibility, pasteboard: pasteboard, keystrokes: keystrokes, workspace: workspace,
                clock: clock)
            let environment = PipelineEnvironment(
                workspace: workspace, pasteboard: pasteboard, clock: ManualWallClock(F.pressedAt),
                focus: focus ?? AXFocusProbe(workspace: workspace, accessibility: accessibility),
                audio: ScriptedAudioInput(summary: F.speech), engine: StubEngine(text: text),
                resolver: UtteranceResolver(settings: settings), inserter: inserter)
            controller = PipelineController(
                environment: environment, log: UtteranceLog(directory: directory.url, timeZone: F.paris))
        }

        /// Presses, waits for the probe, runs `meanwhile`, releases, and returns the one record written.
        func press(meanwhile: () -> Void = {}) async throws -> UtteranceRecord {
            var snapshots = controller.snapshots.makeAsyncIterator()
            await controller.triggerDown()
            while let snapshot = await snapshots.next(), snapshot.utterance?.focus == nil {}
            meanwhile()
            await controller.triggerUp()
            while let snapshot = await snapshots.next() {
                if snapshot.phase == .idle, let record = snapshot.lastRecord { return record }
            }
            throw CancellationError()
        }
    }

    private static let textArea = FocusedElement(role: "AXTextArea", acceptsSelectedText: true, valueSettable: true)
    private static let caretInsert = AXInsertionReport(
        setSucceeded: true, before: AXTextState(selectionLocation: 0, selectionLength: 0, characterCount: 0),
        after: AXTextState(selectionLocation: 12, selectionLength: 0, characterCount: 12), readBack: "Hello there.")

    @Test func aNativeTextFieldTakesAnAXInsertion() async throws {
        let rig = try Rig(frontmost: F.mail)
        rig.accessibility.set(element: Self.textArea, for: F.mail.processID)
        rig.accessibility.set(report: Self.caretInsert)

        let record = try await rig.press()

        #expect(record.resolution == .textInserted && record.error == nil)
        #expect(record.targetApp == "com.apple.mail" && record.modelTier == .small)
        #expect(record.rawText == "Hello there." && record.normalizedText == "hello there")
        #expect(rig.accessibility.insertions.map(\.text) == ["Hello there."])
        #expect(rig.pasteboard.writes.isEmpty)
    }

    @Test func anElectronAppThatHidesItsTreeGetsAPaste() async throws {
        let slack = AppIdentity(bundleID: "com.example.chat", name: "Chat", processID: 900, embedsChromium: true)
        let rig = try Rig(frontmost: slack)

        let record = try await rig.press()

        #expect(record.resolution == .textInserted && record.targetApp == "com.example.chat")
        #expect(rig.accessibility.insertions.isEmpty)
        #expect(rig.keystrokes.posted == [.paste])
        #expect(rig.pasteboard.writes.map(\.markers) == [[PasteboardMarker.transient]])
    }

    @Test func aPasteNobodyReadsIsLoggedAsClipboardText() async throws {
        let chat = AppIdentity(bundleID: "com.example.chat", name: "Chat", processID: 900, embedsChromium: true)
        let rig = try Rig(frontmost: chat)
        rig.keystrokes.noAppReads()

        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        await rig.controller.triggerDown()
        await rig.controller.triggerUp()
        await rig.clock.waitForSleeps(1)
        rig.clock.advance(by: TextInserter.defaultReadDeadline)
        var found: UtteranceRecord?
        while found == nil, let snapshot = await snapshots.next() {
            if snapshot.phase == .idle { found = snapshot.lastRecord }
        }
        let record = try #require(found)

        #expect(record.resolution == .textClipboard && record.error == "paste_not_consumed")
        #expect(rig.pasteboard.text == "Hello there.")
        #expect(rig.pasteboard.writes.last?.markers == [], "the copy the user keeps is not marked transient")
    }

    @Test func focusThatMovesBeforeInsertionLeavesTheTextOnTheClipboard() async throws {
        let rig = try Rig(frontmost: F.mail)
        rig.accessibility.set(element: Self.textArea, for: F.mail.processID)
        rig.accessibility.set(report: Self.caretInsert)

        let record = try await rig.press {
            rig.workspace.switchTo(AppIdentity(bundleID: "com.apple.Notes", name: "Notes", processID: 777))
        }

        #expect(record.resolution == .textClipboard && record.error == "focus_changed")
        #expect(record.targetApp == "com.apple.mail", "the app the user spoke into, not the one they moved to")
        #expect(rig.accessibility.insertions.isEmpty)
        #expect(rig.pasteboard.text == "Hello there." && rig.pasteboard.writes.map(\.markers) == [[]])
    }

    @Test func aPasswordFieldGetsAConcealedCopyAndAnEmptyLogLine() async throws {
        let rig = try Rig(frontmost: F.mail, text: "hunter2")
        let field = FocusedElement(role: "AXTextField", subrole: FocusedElement.secureTextFieldSubrole)
        rig.accessibility.set(element: field, for: F.mail.processID)

        let record = try await rig.press()

        #expect(record.resolution == .textClipboard && record.error == "secure_field")
        #expect(record.rawText == nil && record.normalizedText == nil)
        #expect(rig.accessibility.insertions.isEmpty && rig.keystrokes.posted.isEmpty)
        #expect(rig.pasteboard.writes.map(\.markers) == [[PasteboardMarker.concealed]])
    }

    /// The transcript is ready before the probe answers, and the field turns out to be a password field.
    @Test func aSlowProbeIsWaitedForBeforeTheTextGoesAnywhere() async throws {
        let probe = GatedFocusProbe(FocusSnapshot(app: F.mail, isSecureInput: true))
        let rig = try Rig(frontmost: F.mail, text: "hunter2", focus: probe)
        var snapshots = rig.controller.snapshots.makeAsyncIterator()

        await rig.controller.triggerDown()
        await rig.controller.triggerUp()
        while let snapshot = await snapshots.next(), snapshot.phase != .resolving {}
        #expect(rig.pasteboard.writes.isEmpty, "nothing is copied while the focus is unknown")
        probe.open()
        var record: UtteranceRecord?
        while record == nil, let snapshot = await snapshots.next() {
            if snapshot.phase == .idle { record = snapshot.lastRecord }
        }

        #expect(record?.resolution == .textClipboard && record?.rawText == nil && record?.normalizedText == nil)
        #expect(rig.pasteboard.writes.map(\.markers) == [[PasteboardMarker.concealed]])
    }

    @Test func aNativeAppThatAnswersNothingGetsTheClipboard() async throws {
        let rig = try Rig(frontmost: F.mail)

        let record = try await rig.press()

        #expect(record.resolution == .textClipboard && record.error == "no_text_field")
        #expect(rig.keystrokes.posted.isEmpty && rig.pasteboard.text == "Hello there.")
    }

    /// A second dictation into the same field: the field says the caret sits after a full stop, so the text goes
    /// in with a space, and the read-back that confirms it expects the spaced text.
    @Test func aSecondDictationIntoTheSameFieldGetsALeadingSpace() async throws {
        let rig = try Rig(frontmost: F.mail)
        rig.accessibility.set(element: Self.textArea, for: F.mail.processID)
        rig.accessibility.set(characterBeforeInsertion: ".", for: F.mail.processID)
        rig.accessibility.set(
            report: AXInsertionReport(
                setSucceeded: true, before: AXTextState(selectionLocation: 12, selectionLength: 0, characterCount: 12),
                after: AXTextState(selectionLocation: 25, selectionLength: 0, characterCount: 25),
                readBack: " Hello there."))

        let record = try await rig.press()

        #expect(record.resolution == .textInserted)
        #expect(rig.accessibility.insertions.map(\.text) == [" Hello there."])
        #expect(record.rawText == "Hello there.", "the log records what was said, not what was typed")
    }

    /// A field that answers nothing about the caret — most paste targets — changes nothing about the text.
    @Test func anAppThatDoesNotSayWhatPrecedesTheCaretGetsTheTextAsItIs() async throws {
        let chat = AppIdentity(bundleID: "com.example.chat", name: "Chat", processID: 900, embedsChromium: true)
        let rig = try Rig(frontmost: chat)

        let record = try await rig.press()

        #expect(record.resolution == .textInserted)
        #expect(rig.pasteboard.writes.first?.text == "Hello there.")
    }

    /// M5's first item, which M4 already satisfied: a focused element that is not text goes to the clipboard
    /// rather than being typed into a button.
    @Test func aButtonWithFocusGetsTheClipboard() async throws {
        let rig = try Rig(frontmost: F.mail)
        rig.accessibility.set(element: FocusedElement(role: "AXButton"), for: F.mail.processID)

        let record = try await rig.press()

        #expect(record.resolution == .textClipboard && record.error == "no_text_field")
        #expect(rig.accessibility.insertions.isEmpty && rig.keystrokes.posted.isEmpty)
        #expect(rig.pasteboard.text == "Hello there.")
    }

    @Test func theFallbackOffDiscardsTextWithNowhereToGo() async throws {
        let rig = try Rig(frontmost: F.mail)
        rig.settings.update(clipboardFallback: false)

        let record = try await rig.press()

        #expect(record.resolution == .discarded && record.error == "clipboard_fallback_disabled")
        #expect(record.rawText == "Hello there.", "the log still says what was heard")
        #expect(rig.pasteboard.writes.isEmpty, "the user's clipboard is left alone")
    }

    @Test func theFallbackOffDiscardsTextAnInsertionFailedToDeliver() async throws {
        let rig = try Rig(frontmost: F.mail)
        rig.accessibility.set(element: Self.textArea, for: F.mail.processID)
        rig.accessibility.set(report: Self.caretInsert)
        rig.settings.update(clipboardFallback: false)

        let record = try await rig.press {
            rig.workspace.switchTo(AppIdentity(bundleID: "com.apple.Notes", name: "Notes", processID: 777))
        }

        #expect(record.resolution == .discarded && record.error == "clipboard_fallback_disabled")
        #expect(rig.accessibility.insertions.isEmpty && rig.pasteboard.writes.isEmpty)
    }

    /// The audit's P1: with the fallback off, a paste nobody reads must not leave the dictation sitting on the
    /// user's clipboard while the one log line for that utterance says it was discarded. The pasteboard was
    /// borrowed for the paste, so it goes back.
    @Test func theFallbackOffGivesTheClipboardBackWhenNothingReadsThePaste() async throws {
        let chat = AppIdentity(bundleID: "com.example.chat", name: "Chat", processID: 900, embedsChromium: true)
        let rig = try Rig(frontmost: chat)
        rig.keystrokes.noAppReads()
        rig.settings.update(clipboardFallback: false)

        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        await rig.controller.triggerDown()
        await rig.controller.triggerUp()
        await rig.clock.waitForSleeps(1)
        rig.clock.advance(by: TextInserter.defaultReadDeadline)
        var found: UtteranceRecord?
        while found == nil, let snapshot = await snapshots.next() {
            if snapshot.phase == .idle { found = snapshot.lastRecord }
        }
        let record = try #require(found)

        #expect(record.resolution == .discarded && record.error == "clipboard_fallback_disabled")
        await eventually { rig.pasteboard.text == "original" }
        #expect(rig.pasteboard.text == "original", "the log says discarded, so the clipboard must say so too")
    }

    /// With the fallback on, the same paste leaves the text there on purpose — that is M4 review finding 5.
    @Test func theFallbackOnStillLeavesAnUnreadPasteOnTheClipboard() async throws {
        let chat = AppIdentity(bundleID: "com.example.chat", name: "Chat", processID: 900, embedsChromium: true)
        let rig = try Rig(frontmost: chat)
        rig.keystrokes.noAppReads()

        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        await rig.controller.triggerDown()
        await rig.controller.triggerUp()
        await rig.clock.waitForSleeps(1)
        rig.clock.advance(by: TextInserter.defaultReadDeadline)
        var found: UtteranceRecord?
        while found == nil, let snapshot = await snapshots.next() {
            if snapshot.phase == .idle { found = snapshot.lastRecord }
        }

        #expect(found?.resolution == .textClipboard && found?.error == "paste_not_consumed")
        #expect(rig.pasteboard.text == "Hello there.")
    }

    /// Clipboard-only mode is the destination the user chose, so the fallback setting does not touch it.
    @Test func theFallbackOffLeavesClipboardOnlyModeAlone() async throws {
        let rig = try Rig(frontmost: F.mail)
        rig.accessibility.set(element: Self.textArea, for: F.mail.processID)
        rig.settings.update(insertionMode: .clipboard)
        rig.settings.update(clipboardFallback: false)

        let record = try await rig.press()

        #expect(record.resolution == .textClipboard && rig.pasteboard.text == "Hello there.")
    }

    @Test func anAXInsertionTheFieldIgnoredIsPasted() async throws {
        let rig = try Rig(frontmost: F.mail)
        rig.accessibility.set(element: Self.textArea, for: F.mail.processID)
        rig.accessibility.set(
            report: AXInsertionReport(
                setSucceeded: true, before: AXTextState(selectionLocation: 3, selectionLength: 0, characterCount: 3),
                after: AXTextState(selectionLocation: 3, selectionLength: 0, characterCount: 3)))

        let record = try await rig.press()

        #expect(record.resolution == .textInserted)
        #expect(rig.accessibility.insertions.count == 1 && rig.keystrokes.posted == [.paste])
    }

    @Test func theClipboardModeNeverTypes() async throws {
        let rig = try Rig(frontmost: F.mail)
        rig.accessibility.set(element: Self.textArea, for: F.mail.processID)
        rig.settings.update(insertionMode: .clipboard)

        let record = try await rig.press()

        #expect(record.resolution == .textClipboard)
        #expect(rig.accessibility.insertions.isEmpty && rig.keystrokes.posted.isEmpty)
    }
}
