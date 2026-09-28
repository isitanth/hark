import Foundation
import HarkCore
import Testing

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
}
