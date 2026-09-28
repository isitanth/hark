import Foundation
import HarkCore
import Testing

private typealias F = Fixture

private let at = Fixture.pressedAt
private let blank = CaptureIntent.ask(SelectionSnapshot(text: " \n\t", caller: F.textEdit))
private let done = LLMCallSummary(model: F.bonsai, ms: 2_610, finishReason: "stop")
private let failures: [(LLMFailure, String)] = [
    (.notRunning(endpoint: "127.0.0.1:8002"), "llm_unreachable"), (.keyRefused, "llm_unauthorized"),
    (.noKey, "llm_unauthorized"), (.noAnswer, "llm_timeout"), (.server(status: 500, message: "boom"), "llm_error:500"),
    (.server(status: nil, message: "overloaded"), "llm_error"), (.empty, "llm_empty"),
]

/// The ask's rows, in the shape of `legalTransitions`. `PipelineReducerTests.everyFailureAndDiscardReasonIsCovered`
/// reads both tables.
let askTransitions: [LegalTransition] =
    [
        .init(
            name: "idle, ask: capture only, the caller is the focus", state: .idle,
            event: .triggerDown(F.id, at: at, intent: F.ask), phase: .capturing, effects: ["startCapture"]),
        .init(
            name: "idle, ask on a blank selection: nothing is captured", state: .idle,
            event: .triggerDown(F.id, at: at, intent: blank), phase: .idle, effects: ["log:discarded:empty_selection"]),
        .init(
            name: "capturing a dictation, ask is busy", state: F.capturingFocused,
            event: .triggerDown(F.other, at: at, intent: F.ask), phase: .capturing, effects: ["log:discarded:busy"]),
        .init(
            name: "capturing an ask, talk key is busy", state: F.askCapturing, event: .triggerDown(F.other, at: at),
            phase: .capturing, effects: ["log:discarded:busy"]),
        .init(
            name: "capturing an ask, Done", state: F.askCapturing, event: .triggerUp(at: at), phase: .transcribing,
            effects: ["stopCapture"]),
        .init(
            name: "capturing an ask, cancel", state: F.askCapturing, event: .cancel, phase: .idle,
            effects: ["cancelCapture", "log:discarded:cancelled"]),
        .init(
            name: "transcribing an ask, instruction heard: generate", state: F.askTranscribing,
            event: .transcribed(F.id, F.instruction, ms: 380), phase: .asking, effects: ["generate"]),
        .init(
            name: "transcribing an ask, nothing heard", state: F.askTranscribing,
            event: .transcribed(F.id, Transcript(raw: " "), ms: 300), phase: .idle,
            effects: ["log:discarded:empty_transcript"]),
        .init(
            name: "generating, answer complete: review", state: F.generating, event: .generated(F.id, done),
            phase: .asking, effects: []),
        .init(
            name: "generating, cancel closes the stream", state: F.generating, event: .cancel, phase: .idle,
            effects: ["cancelGeneration", "log:discarded:cancelled"]),
        .init(
            name: "generating, talk key is busy", state: F.generating, event: .triggerDown(F.other, at: at),
            phase: .asking, effects: ["log:discarded:busy"]),
        .init(
            name: "reviewing, Copy", state: F.reviewing, event: .askCopy(F.id, F.answer), phase: .copying,
            effects: ["copyToClipboard"]),
        .init(
            name: "reviewing, cancel", state: F.reviewing, event: .cancel, phase: .idle,
            effects: ["log:discarded:cancelled"]),
        .init(
            name: "reviewing, talk key is busy", state: F.reviewing, event: .triggerDown(F.other, at: at),
            phase: .asking, effects: ["log:discarded:busy"]),
        .init(
            name: "reviewing, another ask is busy", state: F.reviewing,
            event: .triggerDown(F.other, at: at, intent: F.ask), phase: .asking, effects: ["log:discarded:busy"]),
        .init(
            name: "reviewing, Replace: check the selection first", state: F.reviewing,
            event: .askReplace(F.id, F.answer), phase: .asking, effects: ["checkSelection"]),
        .init(
            name: "replacing, intact: insert the answer", state: F.replacing,
            event: .selectionChecked(F.id, SelectionCheck(verdict: .intact, focus: F.backInTextEdit, plan: .axInsert)),
            phase: .inserting, effects: ["insert"]),
        .init(
            name: "replacing, the selection changed: the clipboard", state: F.replacing,
            event: .selectionChecked(F.id, SelectionCheck(verdict: .changed, focus: F.backInTextEdit)),
            phase: .copying, effects: ["copyToClipboard"]),
        .init(
            name: "replacing, another app in front: the clipboard", state: F.replacing,
            event: .selectionChecked(F.id, SelectionCheck(verdict: .otherApp, focus: F.focus)),
            phase: .copying, effects: ["copyToClipboard"]),
        .init(
            name: "replacing, intact but nothing takes text: the clipboard", state: F.replacing,
            event: .selectionChecked(F.id, SelectionCheck(verdict: .intact, focus: FocusSnapshot(app: F.textEdit))),
            phase: .copying, effects: ["copyToClipboard"]),
        .init(
            name: "replacing, quit", state: F.replacing, event: .cancel, phase: .idle,
            effects: ["log:discarded:cancelled"]),
        .init(
            name: "replacing, talk key is busy", state: F.replacing, event: .triggerDown(F.other, at: at),
            phase: .asking, effects: ["log:discarded:busy"]),
        .init(
            name: "copying an answer, done after the selection changed",
            state: .copying(F.askContext(), F.instruction, .fallback(.selectionChanged)), event: .copied(F.id),
            phase: .idle, effects: ["log:text_clipboard:selection_changed"]),
        .init(
            name: "inserting an answer, done",
            state: .inserting(F.askContext(llmModel: F.bonsai, llmMs: 2_610), F.instruction, .axInsert),
            event: .inserted(F.id), phase: .idle, effects: ["log:text_inserted"]),
        .init(
            name: "failed, Retry sends it again", state: F.askFailed(.noAnswer), event: .askRetry(F.id),
            phase: .asking, effects: ["generate"]),
        .init(
            name: "failed, talk key is busy", state: F.askFailed(.keyRefused), event: .triggerDown(F.other, at: at),
            phase: .asking, effects: ["log:discarded:busy"]),
        .init(
            name: "copying an answer, done: the clipboard was chosen",
            state: .copying(F.askContext(llmModel: F.bonsai, llmMs: 2_610), F.instruction, .chosen),
            event: .copied(F.id), phase: .idle, effects: ["log:text_clipboard"]),
    ]
    + failures.flatMap { failure, code -> [LegalTransition] in
        [
            .init(
                name: "generating, \(code): the popup shows it", state: F.generating,
                event: .generationFailed(F.id, failure, LLMCallSummary(ms: 900)), phase: .asking, effects: []),
            .init(
                name: "failed with \(code), cancel logs it", state: F.askFailed(failure), event: .cancel,
                phase: .idle, effects: ["log:failed:\(code)"]),
        ]
    }

let illegalAskTransitions: [IllegalTransition] = [
    .init(name: "capturing an ask, a focus probe answers", state: F.askCapturing, event: .focusCaptured(F.id, F.focus)),
    .init(name: "generating, Copy before the end", state: F.generating, event: .askCopy(F.id, F.answer)),
    .init(name: "generating, Retry", state: F.generating, event: .askRetry(F.id)),
    .init(name: "generating, a late release", state: F.generating, event: .triggerUp(at: at)),
    .init(name: "generating, end of another ask", state: F.generating, event: .generated(F.other, done)),
    .init(name: "reviewing, a second end", state: F.reviewing, event: .generated(F.id, done)),
    .init(name: "reviewing, a late failure", state: F.reviewing, event: .generationFailed(F.id, .empty, .init())),
    .init(name: "reviewing, Retry", state: F.reviewing, event: .askRetry(F.id)),
    .init(name: "reviewing, Copy for another ask", state: F.reviewing, event: .askCopy(F.other, F.answer)),
    .init(name: "failed, Copy", state: F.askFailed(.empty), event: .askCopy(F.id, F.answer)),
    .init(name: "failed, Replace", state: F.askFailed(.empty), event: .askReplace(F.id, F.answer)),
    .init(name: "generating, Replace", state: F.generating, event: .askReplace(F.id, F.answer)),
    .init(name: "replacing, a second Replace", state: F.replacing, event: .askReplace(F.id, F.answer)),
    .init(name: "replacing, Copy", state: F.replacing, event: .askCopy(F.id, F.answer)),
    .init(
        name: "reviewing, a check nobody asked for", state: F.reviewing,
        event: .selectionChecked(F.id, SelectionCheck(verdict: .intact, focus: F.backInTextEdit, plan: .paste))),
    .init(name: "failed, a late end", state: F.askFailed(.noAnswer), event: .generated(F.id, done)),
    .init(name: "idle, a late Retry", state: .idle, event: .askRetry(F.id)),
    .init(name: "idle, a late Copy", state: .idle, event: .askCopy(F.id, F.answer)),
    .init(name: "idle, a late end", state: .idle, event: .generated(F.id, done)),
    .init(name: "copying an answer, cancel is too late", state: F.copying, event: .cancel),
    .init(name: "dictation resolving, an answer", state: F.resolving, event: .generated(F.id, done)),
]

private func down(_ n: UInt64, _ intent: CaptureIntent = .dictate) -> PipelineEvent {
    .triggerDown(UtteranceID(n), at: F.pressedAt.addingTimeInterval(Double(n)), intent: intent)
}
private func up(_ n: UInt64) -> PipelineEvent { .triggerUp(at: F.pressedAt.addingTimeInterval(Double(n) + 1.8)) }
private func heard(_ n: UInt64) -> [PipelineEvent] {
    [up(n), .captured(UtteranceID(n), F.speech), .transcribed(UtteranceID(n), F.instruction, ms: 380)]
}

/// Whole asks, for `LogOnceTests`: one line per press, whatever the popup does.
let askPressSequences: [PressSequence] = [
    .init(
        name: "ask, Copy",
        events: [down(1, F.ask)] + heard(1)
            + [.generated(UtteranceID(1), done), .askCopy(UtteranceID(1), F.answer), .copied(UtteranceID(1))],
        logs: ["log:text_clipboard"]),
    .init(
        name: "ask, the talk key twice while it streams, then Cancel",
        events: [down(1, F.ask)] + heard(1) + [down(2), up(2), down(3), .cancel, .generated(UtteranceID(1), done)],
        logs: ["log:discarded:busy", "log:discarded:busy", "log:discarded:cancelled"]),
    .init(
        name: "ask fails, Retry, fails again, Cancel",
        events: [down(1, F.ask)] + heard(1) + [
            .generationFailed(UtteranceID(1), .noAnswer, LLMCallSummary(ms: 15_000)), .askRetry(UtteranceID(1)),
            .generationFailed(UtteranceID(1), .notRunning(endpoint: "127.0.0.1:8002"), LLMCallSummary(ms: 1)),
            .cancel, .askRetry(UtteranceID(1)),
        ],
        logs: ["log:failed:llm_unreachable"]),
    .init(
        name: "ask on a blank selection, then a dictation",
        events: [down(1, blank), down(2), .focusCaptured(UtteranceID(2), F.focus), .cancel],
        logs: ["log:discarded:empty_selection", "log:discarded:cancelled"]),
    .init(
        name: "ask during a dictation is busy", events: [down(1), down(2, F.ask), .cancel],
        logs: ["log:discarded:busy", "log:discarded:cancelled"]),
]

@Suite struct AskTransitionTests {
    let reducer = PipelineReducer()

    @Test(arguments: askTransitions)
    func legal(_ transition: LegalTransition) throws {
        let result = try reducer.reduce(transition.state, transition.event).get()
        #expect(result.state.phase == transition.phase)
        #expect(result.effects.map(\.label) == transition.effects)
    }

    @Test(arguments: illegalAskTransitions)
    func illegal(_ transition: IllegalTransition) {
        let result = reducer.reduce(transition.state, transition.event)
        #expect(result == .failure(Rejection(phase: transition.state.phase, event: transition.event)))
    }

    /// Hark is in front during a Services call: the caller from the snapshot is the focus, not a probe.
    @Test func anAskTakesItsFocusFromTheSelection() throws {
        let start = try reducer.reduce(.idle, .triggerDown(F.id, at: at, intent: F.ask)).get()
        #expect(start.effects == [.startCapture(F.id)])
        #expect(start.state.context?.focus == FocusSnapshot(app: F.textEdit))
    }

    @Test func theInstructionIsSentAsHeardWithTheSelection() throws {
        let asking = try reducer.reduce(F.askTranscribing, .transcribed(F.id, F.instruction, ms: 380)).get()
        #expect(asking.effects == [.generate(F.id, instruction: "Résume ce texte.", selection: F.selection)])
        #expect(asking.state.ask == AskProgress(instruction: "Résume ce texte.", stage: .generating))
        guard case .asking(let context, let transcript, _) = asking.state else {
            Issue.record("not asking")
            return
        }
        #expect(transcript.normalized == Normalizer.normalize("Résume ce texte."))
        #expect(context.transcribeMs == 380)
    }

    @Test func theAnswerIsWhatIsCopiedAndTheCallIsWhatIsLogged() throws {
        let reviewing = try reducer.reduce(F.generating, .generated(F.id, done)).get()
        let copying = try reducer.reduce(reviewing.state, .askCopy(F.id, F.answer)).get()
        #expect(copying.effects == [.copyToClipboard(F.id, F.answer, concealed: false)])
        let record = try #require(try reducer.reduce(copying.state, .copied(F.id)).get().effects.first?.record)
        #expect(record.resolution == .textClipboard && record.error == nil)
        #expect(record.actionType == .ask && record.targetApp == "com.apple.TextEdit")
        #expect(record.llmModel == F.bonsai && record.llmMs == 2_610)
        #expect(record.rawText == "Résume ce texte.")
    }

    @Test func aRetryForgetsTheFailedCall() throws {
        let retried = try reducer.reduce(F.askFailed(.noAnswer, llmMs: 15_000), .askRetry(F.id)).get()
        #expect(retried.effects == [.generate(F.id, instruction: "Résume ce texte.", selection: F.selection)])
        #expect(retried.state.context?.llmMs == nil && retried.state.context?.llmModel == nil)
    }

    @Test func aFailedAskKeepsTheCallOnItsLine() throws {
        let failed = try reducer.reduce(F.generating, .generationFailed(F.id, .noAnswer, LLMCallSummary(ms: 15_000)))
            .get()
        #expect(failed.state.ask?.stage == .failed(.noAnswer))
        let record = try #require(try reducer.reduce(failed.state, .cancel).get().effects.first?.record)
        #expect(record.resolution == .failed && record.error == "llm_timeout" && record.llmMs == 15_000)
    }
}

extension AskTransitionTests {
    /// CLAUDE.md: the selected text and the suggestion are never written to disk. Every line of every ask sequence,
    /// and every row of the table, is checked for a word of either.
    @Test(arguments: askPressSequences)
    func noLineHoldsTheSelectionOrTheAnswer(_ sequence: PressSequence) {
        var state = PipelineState.idle
        var lines: [String] = []
        for event in sequence.events {
            guard case .success(let transition) = reducer.reduce(state, event) else { continue }
            state = transition.state
            lines += transition.effects.compactMap { $0.record?.jsonLine(timeZone: F.paris) }
        }
        #expect(!lines.isEmpty)
        for line in lines {
            for word in ["comité", "budget", "Réunion", "validation"] {
                #expect(!line.contains(word), "\(line)")
            }
        }
    }

    @Test func noRowOfTheTableLogsTheSelection() throws {
        for row in askTransitions {
            let effects = try reducer.reduce(row.state, row.event).get().effects
            for line in effects.compactMap({ $0.record?.jsonLine(timeZone: F.paris) }) {
                #expect(!line.contains("comité") && !line.contains("budget"), "\(row.name)")
            }
        }
    }
}

extension AskTransitionTests {
    /// Replace writes the answer as edited, where the check found the focus, with the clipboard to catch a failure.
    @Test func replaceInsertsTheAnswerIntoTheFieldTheCheckFound() throws {
        let check = SelectionCheck(verdict: .intact, focus: F.backInTextEdit, plan: .axInsert)
        let inserting = try reducer.reduce(F.replacing, .selectionChecked(F.id, check)).get()
        #expect(inserting.effects == [.insert(F.id, F.answer, .axInsert, F.backInTextEdit, clipboardFallback: true)])
        let failed = try reducer.reduce(inserting.state, .failed(F.id, .insertionFailed)).get()
        #expect(failed.effects == [.copyToClipboard(F.id, F.answer, concealed: false)])
        let record = try #require(try reducer.reduce(failed.state, .copied(F.id)).get().effects.first?.record)
        #expect(record.error == "insertion_failed" && record.actionType == .ask && record.llmMs == 2_610)
    }

    /// A changed selection keeps the caller on the line: the ask was about it, not about the app now in front.
    @Test func aChangedSelectionKeepsTheAnswerAndTheCaller() throws {
        let check = SelectionCheck(verdict: .otherApp, focus: F.focus)
        let copying = try reducer.reduce(F.replacing, .selectionChecked(F.id, check)).get()
        #expect(copying.effects == [.copyToClipboard(F.id, F.answer, concealed: false)])
        let record = try #require(try reducer.reduce(copying.state, .copied(F.id)).get().effects.first?.record)
        #expect(record.resolution == .textClipboard && record.error == "selection_changed")
        #expect(record.targetApp == "com.apple.TextEdit")
    }
}
