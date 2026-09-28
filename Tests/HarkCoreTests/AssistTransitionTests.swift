import Foundation
import HarkCore
import Testing

private typealias F = Fixture

private let at = Fixture.pressedAt
private let done = LLMCallSummary(model: F.bonsai, ms: 2_610, finishReason: "stop")

/// The assistant's rows (M9.1): the Ask key with nothing selected. The same asking stages as an ask, with a focus probe
/// at the press, no selection sent, and Insert going through the same check as Replace with nothing selected expected.
let assistTransitions: [LegalTransition] = [
    .init(
        name: "idle, assistant: capture and probe the focus", state: .idle,
        event: .triggerDown(F.id, at: at, intent: F.assist), phase: .capturing, effects: ["startCapture", "probeFocus"]),
    .init(
        name: "capturing the assistant, the probe answers", state: F.assistCapturing,
        event: .focusCaptured(F.id, F.backInTextEdit), phase: .capturing, effects: []),
    .init(
        name: "capturing a dictation, the assistant is busy", state: F.capturingFocused,
        event: .triggerDown(F.other, at: at, intent: F.assist), phase: .capturing, effects: ["log:discarded:busy"]),
    .init(
        name: "capturing the assistant, talk key is busy", state: F.assistCapturing,
        event: .triggerDown(F.other, at: at), phase: .capturing, effects: ["log:discarded:busy"]),
    .init(
        name: "capturing the assistant, cancel", state: F.assistCapturing, event: .cancel, phase: .idle,
        effects: ["cancelCapture", "log:discarded:cancelled"]),
    .init(
        name: "transcribing the assistant, request heard: generate", state: F.assistTranscribing,
        event: .transcribed(F.id, F.request, ms: 380), phase: .asking, effects: ["generate"]),
    .init(
        name: "transcribing the assistant, nothing heard", state: F.assistTranscribing,
        event: .transcribed(F.id, Transcript(raw: " "), ms: 300), phase: .idle,
        effects: ["log:discarded:empty_transcript"]),
    .init(
        name: "generating, a late probe still counts",
        state: .asking(F.assistContext(focus: nil), F.request, .generating),
        event: .focusCaptured(F.id, F.backInTextEdit), phase: .asking, effects: []),
    .init(
        name: "reviewing the assistant, Copy", state: F.assistReviewing, event: .askCopy(F.id, F.answer),
        phase: .copying, effects: ["copyToClipboard"]),
    .init(
        name: "reviewing the assistant, Insert: check nothing got selected", state: F.assistReviewing,
        event: .askReplace(F.id, F.answer), phase: .asking, effects: ["checkSelection"]),
    .init(
        name: "inserting, still nothing selected: insert at the caret", state: F.assistInserting,
        event: .selectionChecked(F.id, SelectionCheck(verdict: .intact, focus: F.backInTextEdit, plan: .axInsert)),
        phase: .inserting, effects: ["insert"]),
    .init(
        name: "inserting, text got selected meanwhile: the clipboard", state: F.assistInserting,
        event: .selectionChecked(F.id, SelectionCheck(verdict: .changed, focus: F.backInTextEdit)),
        phase: .copying, effects: ["copyToClipboard"]),
    .init(
        name: "inserting, nothing takes text: the clipboard", state: F.assistInserting,
        event: .selectionChecked(F.id, SelectionCheck(verdict: .intact, focus: FocusSnapshot(app: F.textEdit))),
        phase: .copying, effects: ["copyToClipboard"]),
    .init(
        name: "inserting the answer, done",
        state: .inserting(F.assistContext(llmModel: F.bonsai, llmMs: 2_610), F.request, .axInsert),
        event: .inserted(F.id), phase: .idle, effects: ["log:text_inserted"]),
    .init(
        name: "failed, Retry sends the request again",
        state: .asking(F.assistContext(llmMs: 15_000), F.request, .failed(.noAnswer)), event: .askRetry(F.id),
        phase: .asking, effects: ["generate"]),
    .init(
        name: "reviewing the assistant, cancel", state: F.assistReviewing, event: .cancel, phase: .idle,
        effects: ["log:discarded:cancelled"]),
]

let illegalAssistTransitions: [IllegalTransition] = [
    .init(
        name: "reviewing the assistant, a second probe", state: F.assistReviewing, event: .focusCaptured(F.id, F.focus)),
    .init(
        name: "generating the assistant, Insert before the end", state: F.assistGenerating,
        event: .askReplace(F.id, F.answer)),
    .init(name: "inserting, a second Insert", state: F.assistInserting, event: .askReplace(F.id, F.answer)),
]

@Suite struct AssistTransitionTests {
    let reducer = PipelineReducer()

    @Test(arguments: assistTransitions)
    func legal(_ transition: LegalTransition) throws {
        let result = try reducer.reduce(transition.state, transition.event).get()
        #expect(result.state.phase == transition.phase)
        #expect(result.effects.map(\.label) == transition.effects)
    }

    @Test(arguments: illegalAssistTransitions)
    func illegal(_ transition: IllegalTransition) {
        let result = reducer.reduce(transition.state, transition.event)
        #expect(result == .failure(Rejection(phase: transition.state.phase, event: transition.event)))
    }

    /// The Ask key leaves the caller in front, so the probe finds it, and nothing is known before it answers.
    @Test func theAssistantStartsWithNoFocus() throws {
        let start = try reducer.reduce(.idle, .triggerDown(F.id, at: at, intent: F.assist)).get()
        #expect(start.state.context?.focus == nil)
    }

    @Test func theRequestIsSentAloneAsHeard() throws {
        let asking = try reducer.reduce(F.assistTranscribing, .transcribed(F.id, F.request, ms: 380)).get()
        #expect(asking.effects == [.generate(F.id, instruction: F.request.raw, selection: nil)])
        let retried = try reducer.reduce(
            .asking(F.assistContext(llmMs: 15_000), F.request, .failed(.noAnswer)), .askRetry(F.id)
        ).get()
        #expect(retried.effects == [.generate(F.id, instruction: F.request.raw, selection: nil)])
    }

    /// Insert must find nothing selected in the app it was pressed in, as Replace must find the selection asked about.
    @Test func insertExpectsNothingSelectedInTheCaller() throws {
        let checking = try reducer.reduce(F.assistReviewing, .askReplace(F.id, F.answer)).get()
        #expect(checking.effects == [.checkSelection(F.id, SelectionSnapshot(text: "", caller: F.textEdit))])
    }

    /// An insert logs as a dictation's would, with the ask's action type and the call that answered.
    @Test func anInsertedAnswerLogsAsAnAsk() throws {
        let inserted = try reducer.reduce(
            .inserting(F.assistContext(llmModel: F.bonsai, llmMs: 2_610), F.request, .axInsert), .inserted(F.id)
        ).get()
        let record = try #require(inserted.effects.first?.record)
        #expect(record.resolution == .textInserted && record.error == nil)
        #expect(record.actionType == .ask && record.targetApp == "com.apple.TextEdit")
        #expect(record.llmModel == F.bonsai && record.llmMs == 2_610)
        #expect(record.rawText == F.request.raw)
    }

    @Test func aCopiedAnswerHasNoError() throws {
        let copying = try reducer.reduce(F.assistReviewing, .askCopy(F.id, F.answer)).get()
        let record = try #require(try reducer.reduce(copying.state, .copied(F.id)).get().effects.first?.record)
        #expect(record.resolution == .textClipboard && record.error == nil && record.actionType == .ask)
    }

    @Test func bothKindsOfAskOpenThePanelAndNeitherIsADictation() {
        #expect(F.assist.isAsk && F.ask.isAsk && !CaptureIntent.dictate.isAsk)
        #expect(F.assist.selection == nil && F.ask.selection == F.selection)
        #expect(CaptureIntent.dictate.expectedSelection == nil)
    }
}

private func down(_ n: UInt64, _ intent: CaptureIntent = .dictate) -> PipelineEvent {
    .triggerDown(UtteranceID(n), at: F.pressedAt.addingTimeInterval(Double(n)), intent: intent)
}
private func heard(_ n: UInt64) -> [PipelineEvent] {
    [
        .triggerUp(at: F.pressedAt.addingTimeInterval(Double(n) + 1.8)), .captured(UtteranceID(n), F.speech),
        .transcribed(UtteranceID(n), F.request, ms: 380),
    ]
}

/// Whole assistant requests, for `LogOnceTests`: one line per press.
let assistPressSequences: [PressSequence] = [
    .init(
        name: "assistant, Insert",
        events: [down(1, F.assist), .focusCaptured(UtteranceID(1), F.backInTextEdit)] + heard(1) + [
            .generated(UtteranceID(1), done), .askReplace(UtteranceID(1), F.answer),
            .selectionChecked(
                UtteranceID(1), SelectionCheck(verdict: .intact, focus: F.backInTextEdit, plan: .axInsert)),
            .inserted(UtteranceID(1)),
        ],
        logs: ["log:text_inserted"]),
    .init(
        name: "assistant, Copy",
        events: [down(1, F.assist), .focusCaptured(UtteranceID(1), F.focus)] + heard(1)
            + [.generated(UtteranceID(1), done), .askCopy(UtteranceID(1), F.answer), .copied(UtteranceID(1))],
        logs: ["log:text_clipboard"]),
    .init(
        name: "assistant, the talk key while it streams, then Cancel",
        events: [down(1, F.assist)] + heard(1) + [down(2), .cancel],
        logs: ["log:discarded:busy", "log:discarded:cancelled"]),
]
