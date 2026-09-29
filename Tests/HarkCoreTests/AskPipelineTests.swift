import Foundation
import HarkCore
import Testing
import os

private typealias F = Fixture

/// Asks end to end through the controller, with the model server scripted: what the reducer tables cannot show, that
/// the answer streams outside the reducer, that Cancel closes the request, and what reaches the clipboard and the log.
@Suite(.timeLimit(.minutes(1)))
struct AskPipelineTests {
    private struct Rig {
        let directory: TemporaryDirectory
        let pasteboard = FakePasteboard(text: nil)
        let asker: ScriptedAsker
        let log: UtteranceLog
        let controller: PipelineController

        init(asker: ScriptedAsker) throws {
            self.asker = asker
            directory = try TemporaryDirectory()
            log = UtteranceLog(directory: directory.url, timeZone: F.paris)
            let environment = PipelineEnvironment(
                workspace: SwitchableWorkspace(F.mail), pasteboard: pasteboard, clock: ManualWallClock(F.pressedAt),
                audio: ScriptedAudioInput(summary: F.speech),
                engine: FixedTranscriptionEngine(transcript: F.instruction), asker: asker)
            controller = PipelineController(environment: environment, log: log)
        }

        func lines() throws -> [String] {
            try String(contentsOf: log.fileURL(for: F.pressedAt), encoding: .utf8).split(separator: "\n")
                .map(String.init)
        }
    }

    private func next(
        _ iterator: inout AsyncStream<PipelineSnapshot>.Iterator, where condition: (PipelineSnapshot) -> Bool
    ) async -> PipelineSnapshot? {
        while let snapshot = await iterator.next() {
            if condition(snapshot) { return snapshot }
        }
        return nil
    }

    private static let finished = LLMEvent.finished(LLMCallSummary(model: F.bonsai, ms: 2_610, finishReason: "stop"))

    @Test func anAskStreamsThenCopiesTheEditedAnswer() async throws {
        let rig = try Rig(asker: ScriptedAsker(pieces: ["Réunion jeudi", " 14 h."], ending: Self.finished))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()

        await rig.controller.triggerDown(intent: F.ask)
        let capturing = try #require(await next(&snapshots) { $0.phase == .capturing })
        let id = try #require(capturing.utterance?.id)
        await rig.controller.finishCapture(id)
        let reviewing = await next(&snapshots) { $0.ask?.stage == .reviewing }
        #expect(reviewing?.ask?.instruction == "Résume ce texte.")

        var updates = rig.controller.askUpdates.makeAsyncIterator()
        #expect(await updates.next() == AskUpdate(id: id, text: "Réunion jeudi 14 h."))
        #expect(rig.asker.requests.map(\.selection) == [F.selectionText])

        await rig.controller.copyAnswer("Réunion jeudi à 14 h.", for: id)
        let done = await next(&snapshots) { $0.phase == .idle && $0.lastRecord != nil }
        let record = try #require(done?.lastRecord)
        #expect(record.resolution == .textClipboard && record.error == nil && record.actionType == .ask)
        #expect(record.llmModel == F.bonsai && record.llmMs == 2_610 && record.targetApp == "com.apple.TextEdit")
        #expect(rig.pasteboard.text == "Réunion jeudi à 14 h.")
        let written = try rig.lines()
        #expect(written.count == 1)
        #expect(!written[0].contains("Réunion") && !written[0].contains("budget"))
    }

    /// The Ask key with nothing selected: the request goes alone, and a Copy logs like an ask's.
    @Test func theAssistantAsksWithoutASelection() async throws {
        let rig = try Rig(asker: ScriptedAsker(pieces: ["Lima."], ending: Self.finished))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()

        await rig.controller.triggerDown(intent: F.assist)
        let id = try #require(await next(&snapshots) { $0.phase == .capturing }?.utterance?.id)
        await rig.controller.finishCapture(id)
        _ = await next(&snapshots) { $0.ask?.stage == .reviewing }
        #expect(rig.asker.requests.map(\.selection) == [nil])
        #expect(rig.asker.requests.map(\.instruction) == [F.instruction.raw])

        await rig.controller.copyAnswer("Lima.", for: id)
        let record = try #require(await next(&snapshots) { $0.phase == .idle && $0.lastRecord != nil }?.lastRecord)
        #expect(record.resolution == .textClipboard && record.error == nil && record.actionType == .ask)
        #expect(rig.pasteboard.text == "Lima.")
        #expect(try rig.lines().count == 1)
    }

    /// Hark's own Copy ends the inserter's watch on the clipboard first, or the watch could put the old contents back.
    @Test func aCopyReleasesThePasteboardFirst() async throws {
        let directory = try TemporaryDirectory()
        let pasteboard = FakePasteboard(text: nil)
        let inserter = ReleaseCountingInserter()
        let controller = PipelineController(
            environment: PipelineEnvironment(
                workspace: SwitchableWorkspace(F.mail), pasteboard: pasteboard, clock: ManualWallClock(F.pressedAt),
                audio: ScriptedAudioInput(summary: F.speech),
                engine: FixedTranscriptionEngine(transcript: F.instruction), inserter: inserter,
                asker: ScriptedAsker(pieces: ["Lima."], ending: Self.finished)),
            log: UtteranceLog(directory: directory.url, timeZone: F.paris))
        var snapshots = controller.snapshots.makeAsyncIterator()
        await controller.triggerDown(intent: F.assist)
        let id = try #require(await next(&snapshots) { $0.phase == .capturing }?.utterance?.id)
        await controller.finishCapture(id)
        _ = await next(&snapshots) { $0.ask?.stage == .reviewing }
        await controller.copyAnswer("Lima.", for: id)
        _ = await next(&snapshots) { $0.phase == .idle && $0.lastRecord != nil }
        #expect(inserter.releases == 1 && pasteboard.text == "Lima.")
    }

    @Test func cancelWhileStreamingClosesTheRequest() async throws {
        let rig = try Rig(asker: ScriptedAsker(pieces: ["Réunion"], ending: nil))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()

        await rig.controller.triggerDown(intent: F.ask)
        let id = try #require(await next(&snapshots) { $0.phase == .capturing }?.utterance?.id)
        await rig.controller.finishCapture(id)
        _ = await next(&snapshots) { $0.ask?.stage == .generating }
        await rig.controller.cancel(id)
        let done = await next(&snapshots) { $0.phase == .idle && $0.lastRecord != nil }

        #expect(done?.lastRecord?.error == "cancelled" && done?.lastRecord?.llmMs == nil)
        for _ in 0..<200 where rig.asker.closedByConsumer == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(rig.asker.closedByConsumer == 1)
        #expect(try rig.lines().count == 1)
    }

    @Test func aFailedAskIsRetriedAndQuitEndsItWithItsFailure() async throws {
        let failing = LLMEvent.failed(.notRunning(endpoint: "127.0.0.1:8002"), LLMCallSummary(ms: 1))
        let rig = try Rig(asker: ScriptedAsker(pieces: [], ending: failing))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()

        await rig.controller.triggerDown(intent: F.ask)
        let id = try #require(await next(&snapshots) { $0.phase == .capturing }?.utterance?.id)
        await rig.controller.finishCapture(id)
        _ = await next(&snapshots) { $0.ask?.stage == .failed(.notRunning(endpoint: "127.0.0.1:8002")) }
        await rig.controller.retryAsk(id)
        _ = await next(&snapshots) { $0.ask?.stage == .generating }
        _ = await next(&snapshots) { $0.ask?.stage == .failed(.notRunning(endpoint: "127.0.0.1:8002")) }
        await rig.controller.quit()

        #expect(rig.asker.requests.count == 2)
        let written = try rig.lines()
        #expect(written.count == 1)
        #expect(written.first?.contains(#""error":"llm_unreachable""#) == true)
    }

    /// A click in the popup after its ask ended must not reach the next utterance.
    @Test func aStaleCancelOrDoneLeavesTheNextUtteranceAlone() async throws {
        let rig = try Rig(asker: ScriptedAsker(pieces: [], ending: Self.finished))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()

        await rig.controller.triggerDown(intent: .ask(SelectionSnapshot(text: "  ", caller: F.textEdit)))
        let first = await next(&snapshots) { $0.lastRecord?.error == "empty_selection" }
        let stale = try #require(first?.lastRecord).timestamp
        #expect(stale == F.pressedAt)
        await rig.controller.triggerDown()
        await rig.controller.cancel(UtteranceID(1))
        await rig.controller.finishCapture(UtteranceID(1))
        #expect(await rig.controller.phase == .capturing)
        await rig.controller.cancel(UtteranceID(2))
        #expect(await rig.controller.phase == .idle)
    }

    /// Replace with the real inserter and checker on fakes: TextEdit in front again, its text view and selection
    /// scripted. Returns the one record, the AX insertions, and the clipboard.
    private func replace(
        selected: String?, edited: String
    ) async throws -> (UtteranceRecord, [(text: String, pid: Int32)], String?) {
        let directory = try TemporaryDirectory()
        let workspace = SwitchableWorkspace(F.textEdit)
        let accessibility = FakeAccessibility()
        let pasteboard = FakePasteboard(text: nil)
        let element = FocusedElement(role: "AXTextArea", acceptsSelectedText: true, valueSettable: true)
        accessibility.set(element: element, for: F.textEdit.processID)
        accessibility.set(selectedText: selected, for: F.textEdit.processID)
        let replaced = F.selectionText.utf16.count
        let written = edited.utf16.count
        accessibility.set(
            report: AXInsertionReport(
                setSucceeded: true,
                before: AXTextState(
                    selectionLocation: 0, selectionLength: replaced,
                    characterCount: replaced),
                after: AXTextState(selectionLocation: written, selectionLength: 0, characterCount: written)))
        let focus = AXFocusProbe(workspace: workspace, accessibility: accessibility)
        let inserter = TextInserter(
            accessibility: accessibility, pasteboard: pasteboard, keystrokes: FakeKeystrokes(target: pasteboard),
            workspace: workspace)
        let environment = PipelineEnvironment(
            workspace: workspace, pasteboard: pasteboard, clock: ManualWallClock(F.pressedAt), focus: focus,
            audio: ScriptedAudioInput(summary: F.speech), engine: FixedTranscriptionEngine(transcript: F.instruction),
            inserter: inserter,
            asker: ScriptedAsker(pieces: [F.answer], ending: Self.finished),
            selection: CallerSelectionChecker(
                workspace: workspace, focus: focus, accessibility: accessibility, settings: ResolutionSettings()))
        let controller = PipelineController(
            environment: environment, log: UtteranceLog(directory: directory.url, timeZone: F.paris))
        var snapshots = controller.snapshots.makeAsyncIterator()

        await controller.triggerDown(intent: F.ask)
        let id = try #require(await next(&snapshots) { $0.phase == .capturing }?.utterance?.id)
        await controller.finishCapture(id)
        _ = await next(&snapshots) { $0.ask?.stage == .reviewing }
        await controller.replaceSelection(with: edited, for: id)
        let done = await next(&snapshots) { $0.phase == .idle && $0.lastRecord != nil }
        return (try #require(done?.lastRecord), accessibility.insertions, pasteboard.text)
    }

    @Test func replaceWritesTheEditedAnswerOverAnIntactSelection() async throws {
        let edited = F.answer + " Merci."
        let (record, insertions, clipboard) = try await replace(selected: F.selectionText, edited: edited)
        #expect(record.resolution == .textInserted && record.error == nil && record.actionType == .ask)
        #expect(record.llmModel == F.bonsai && record.targetApp == "com.apple.TextEdit")
        #expect(insertions.map(\.text) == [edited] && insertions.map(\.pid) == [F.textEdit.processID])
        #expect(clipboard == nil)
    }

    @Test func replaceKeepsTheAnswerOnTheClipboardWhenTheSelectionChanged() async throws {
        let (record, insertions, clipboard) = try await replace(selected: "Le comité", edited: F.answer)
        #expect(record.resolution == .textClipboard && record.error == "selection_changed")
        #expect(insertions.isEmpty)
        #expect(clipboard == F.answer)
    }
}

/// Inserts nothing; counts the times Hark said it was about to write the clipboard itself.
private final class ReleaseCountingInserter: TextInserting {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var releases: Int { count.withLock { $0 } }

    func insert(
        _ text: String, plan: InsertionPlan, focus: FocusSnapshot?, clipboardFallback: Bool
    ) async throws(PipelineFailure) {}

    func releasePasteboard() async { count.withLock { $0 += 1 } }
}
