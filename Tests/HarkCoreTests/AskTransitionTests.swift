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
            name: "generating, answer complete: review", state: F.generating,
            event: .generated(F.id, done, reply: "The answer."),
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
    + followUpTransitions

let illegalAskTransitions: [IllegalTransition] = [
    .init(name: "capturing an ask, a focus probe answers", state: F.askCapturing, event: .focusCaptured(F.id, F.focus)),
    .init(name: "generating, Copy before the end", state: F.generating, event: .askCopy(F.id, F.answer)),
    .init(name: "generating, Retry", state: F.generating, event: .askRetry(F.id)),
    .init(name: "generating, a late release", state: F.generating, event: .triggerUp(at: at)),
    .init(
        name: "generating, end of another ask", state: F.generating,
        event: .generated(F.other, done, reply: "The answer.")),
    .init(name: "reviewing, a second end", state: F.reviewing, event: .generated(F.id, done, reply: "The answer.")),
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
    .init(
        name: "failed, a late end", state: F.askFailed(.noAnswer), event: .generated(F.id, done, reply: "The answer.")),
    .init(name: "idle, a late Retry", state: .idle, event: .askRetry(F.id)),
    .init(name: "idle, a late Copy", state: .idle, event: .askCopy(F.id, F.answer)),
    .init(name: "idle, a late end", state: .idle, event: .generated(F.id, done, reply: "The answer.")),
    .init(name: "copying an answer, cancel is too late", state: F.copying, event: .cancel),
    .init(
        name: "dictation resolving, an answer", state: F.resolving, event: .generated(F.id, done, reply: "The answer.")),
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
            + [
                .generated(UtteranceID(1), done, reply: "The answer."), .askCopy(UtteranceID(1), F.answer),
                .copied(UtteranceID(1)),
            ],
        logs: ["log:text_clipboard"]),
    .init(
        name: "ask, the talk key twice while it streams, then Cancel",
        events: [down(1, F.ask)] + heard(1) + [
            down(2), up(2), down(3), .cancel, .generated(UtteranceID(1), done, reply: "The answer."),
        ],
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
        let reviewing = try reducer.reduce(F.generating, .generated(F.id, done, reply: "The answer.")).get()
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
    /// The project rules: the selected text and the suggestion are never written to disk. Every line of every ask sequence,
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

private let denied = PipelineState.asking(
    F.regionContext(failure: .screenRecordingDenied), F.instruction, .regionFailed(.screenRecordingDenied))
private let captureFailed = PipelineState.asking(
    F.regionContext(failure: .captureFailed), F.instruction, .regionFailed(.captureFailed))

/// A framed region's rows (M11): its events while the request has not left, and the instruction waiting for it.
let regionTransitions: [LegalTransition] =
    [
        (F.regionContext(released: false), PipelineState.capturing),
        (F.regionContext(), PipelineState.transcribing),
    ].flatMap { context, make -> [LegalTransition] in
        let state = make(context)
        let phase = state.phase.rawValue
        return [
            .init(
                name: "\(phase) an ask, a drag begins", state: state, event: .regionStarted(F.id), phase: state.phase,
                effects: []),
            .init(
                name: "\(phase) an ask, the frame is captured", state: state,
                event: .regionCaptured(F.id, F.region), phase: state.phase, effects: []),
            .init(
                name: "\(phase) an ask, the frame failed", state: state,
                event: .regionFailed(F.id, .captureFailed), phase: state.phase, effects: []),
            .init(
                name: "\(phase) an ask, the chip's ×", state: state, event: .regionRemoved(F.id),
                phase: state.phase, effects: []),
            .init(
                name: "\(phase) an ask, the drag framed nothing", state: state, event: .regionAbandoned(F.id),
                phase: state.phase, effects: []),
        ]
    } + [
        .init(
            name: "transcribing the assistant, a drag begins", state: F.assistTranscribing,
            event: .regionStarted(F.id), phase: .transcribing, effects: []),
        .init(
            name: "transcribing an ask with a frame: generate with it",
            state: .transcribing(F.regionContext(region: F.region)),
            event: .transcribed(F.id, F.instruction, ms: 380), phase: .asking, effects: ["generate+region"]),
        .init(
            name: "transcribing an ask, a drag still open: wait for it",
            state: .transcribing(F.regionContext(pending: true)),
            event: .transcribed(F.id, F.instruction, ms: 380), phase: .asking, effects: []),
        .init(
            name: "transcribing an ask, no Screen Recording: the panel says so",
            state: .transcribing(F.regionContext(failure: .screenRecordingDenied)),
            event: .transcribed(F.id, F.instruction, ms: 380), phase: .asking, effects: []),
        .init(
            name: "transcribing an ask, the frame failed: the panel says so",
            state: .transcribing(F.regionContext(failure: .captureFailed)),
            event: .transcribed(F.id, F.instruction, ms: 380), phase: .asking, effects: []),
        .init(
            name: "awaiting the frame, captured: generate with it", state: F.awaitingRegion,
            event: .regionCaptured(F.id, F.region), phase: .asking, effects: ["generate+region"]),
        .init(
            name: "awaiting the frame, it failed", state: F.awaitingRegion,
            event: .regionFailed(F.id, .screenRecordingDenied), phase: .asking, effects: []),
        .init(
            name: "awaiting the frame, another drag", state: F.awaitingRegion, event: .regionStarted(F.id),
            phase: .asking, effects: []),
        .init(
            name: "awaiting the frame, the chip's ×", state: F.awaitingRegion, event: .regionRemoved(F.id),
            phase: .asking, effects: []),
        .init(
            name: "awaiting the frame, the drag framed nothing: generate without it", state: F.awaitingRegion,
            event: .regionAbandoned(F.id), phase: .asking, effects: ["generate"]),
        .init(
            name: "awaiting a new frame, the drag framed nothing: generate with the earlier one",
            state: .asking(F.regionContext(pending: true, region: F.region), F.instruction, .awaitingRegion),
            event: .regionAbandoned(F.id), phase: .asking, effects: ["generate+region"]),
        .init(
            name: "awaiting the frame, cancel", state: F.awaitingRegion, event: .cancel, phase: .idle,
            effects: ["log:discarded:cancelled"]),
        .init(
            name: "awaiting the frame, talk key is busy", state: F.awaitingRegion,
            event: .triggerDown(F.other, at: at), phase: .asking, effects: ["log:discarded:busy"]),
        .init(
            name: "no Screen Recording, cancel logs it", state: denied, event: .cancel, phase: .idle,
            effects: ["log:failed:screen_recording_denied"]),
        .init(
            name: "the frame failed, cancel logs it", state: captureFailed, event: .cancel, phase: .idle,
            effects: ["log:failed:region_failed"]),
        .init(
            name: "no Screen Recording, ask without the frame", state: denied,
            event: .askRetryWithoutRegion(F.id), phase: .asking, effects: ["generate"]),
        .init(
            name: "the model cannot see, Retry keeps the frame", state: F.regionAskFailed, event: .askRetry(F.id),
            phase: .asking, effects: ["generate+region"]),
        .init(
            name: "the model cannot see, ask without the frame", state: F.regionAskFailed,
            event: .askRetryWithoutRegion(F.id), phase: .asking, effects: ["generate"]),
        .init(
            name: "the model cannot see, cancel logs it", state: F.regionAskFailed, event: .cancel, phase: .idle,
            effects: ["log:failed:llm_no_vision"]),
    ]

let illegalRegionTransitions: [IllegalTransition] = [
    .init(name: "capturing a dictation, a drag", state: F.capturingFocused, event: .regionStarted(F.id)),
    .init(name: "transcribing a dictation, a frame", state: F.transcribing, event: .regionCaptured(F.id, F.region)),
    .init(name: "resolving a dictation, a frame", state: F.resolving, event: .regionCaptured(F.id, F.region)),
    .init(
        name: "capturing an ask, another ask's frame", state: F.askCapturing,
        event: .regionCaptured(F.other, F.region)),
    .init(name: "generating, a late drag", state: F.generating, event: .regionStarted(F.id)),
    .init(name: "generating, a late drag that framed nothing", state: F.generating, event: .regionAbandoned(F.id)),
    .init(name: "generating, a late frame", state: F.generating, event: .regionCaptured(F.id, F.region)),
    .init(name: "generating, a late failure", state: F.generating, event: .regionFailed(F.id, .captureFailed)),
    .init(name: "generating, a late ×", state: F.generating, event: .regionRemoved(F.id)),
    .init(name: "reviewing, a late frame", state: F.reviewing, event: .regionCaptured(F.id, F.region)),
    .init(name: "failed, a late frame", state: F.regionAskFailed, event: .regionCaptured(F.id, F.region)),
    .init(name: "the frame failed, a new drag is too late", state: denied, event: .regionStarted(F.id)),
    .init(name: "idle, a late frame", state: .idle, event: .regionCaptured(F.id, F.region)),
    .init(name: "awaiting the frame, Retry", state: F.awaitingRegion, event: .askRetry(F.id)),
    .init(
        name: "awaiting the frame, an answer", state: F.awaitingRegion,
        event: .generated(F.id, done, reply: "The answer.")),
    .init(name: "awaiting the frame, ask without it", state: F.awaitingRegion, event: .askRetryWithoutRegion(F.id)),
    .init(name: "generating, ask without the frame", state: F.generating, event: .askRetryWithoutRegion(F.id)),
    .init(name: "reviewing, ask without the frame", state: F.reviewing, event: .askRetryWithoutRegion(F.id)),
    .init(name: "the frame failed, Retry", state: denied, event: .askRetry(F.id)),
]

@Suite struct RegionTransitionTests {
    let reducer = PipelineReducer()

    @Test(arguments: regionTransitions)
    func legal(_ transition: LegalTransition) throws {
        let result = try reducer.reduce(transition.state, transition.event).get()
        #expect(result.state.phase == transition.phase)
        #expect(result.effects.map(\.label) == transition.effects)
    }

    @Test(arguments: illegalRegionTransitions)
    func illegal(_ transition: IllegalTransition) {
        let result = reducer.reduce(transition.state, transition.event)
        #expect(result == .failure(Rejection(phase: transition.state.phase, event: transition.event)))
    }

    @Test func aDragIsPendingUntilItsFrameArrives() throws {
        let started = try reducer.reduce(F.askCapturing, .regionStarted(F.id)).get().state
        #expect(started.context?.regionPending == true && started.context?.region == nil)
        let captured = try reducer.reduce(started, .regionCaptured(F.id, F.region)).get().state
        #expect(captured.context?.regionPending == false && captured.context?.region == F.region)
        let removed = try reducer.reduce(captured, .regionRemoved(F.id)).get().state
        #expect(removed.context?.region == nil)
    }

    @Test func aFailedFrameIsRememberedAndAFrameClearsIt() throws {
        let started = try reducer.reduce(F.askCapturing, .regionStarted(F.id)).get().state
        let failed = try reducer.reduce(started, .regionFailed(F.id, .screenRecordingDenied)).get().state
        #expect(failed.context?.regionPending == false && failed.context?.regionFailure == .screenRecordingDenied)
        let captured = try reducer.reduce(failed, .regionCaptured(F.id, F.region)).get().state
        #expect(captured.context?.regionFailure == nil)
    }

    /// A failed drag does not outlive the next one, even one that frames nothing, nor the chip's × (M11 review R2).
    @Test func aNewDragOrTheChipsCrossEndsAFailedFrame() throws {
        let failed = try reducer.reduce(F.askCapturing, .regionFailed(F.id, .captureFailed)).get().state
        let again = try reducer.reduce(failed, .regionStarted(F.id)).get().state
        #expect(again.context?.regionFailure == nil && again.context?.regionPending == true)
        let nothing = try reducer.reduce(again, .regionAbandoned(F.id)).get().state
        #expect(nothing.context?.regionFailure == nil && nothing.context?.regionPending == false)
        let framedThenFailed = try reducer.reduce(
            .capturing(F.regionContext(released: false, region: F.region, failure: .captureFailed)),
            .regionRemoved(F.id)
        ).get().state
        #expect(framedThenFailed.context?.regionFailure == nil && framedThenFailed.context?.region == nil)
    }

    @Test func theWaitingInstructionGoesWithTheFrame() throws {
        let waiting = try reducer.reduce(
            .transcribing(F.regionContext(pending: true)), .transcribed(F.id, F.instruction, ms: 380)
        ).get()
        #expect(waiting.state.ask == AskProgress(instruction: "Résume ce texte.", stage: .awaitingRegion))
        let generating = try reducer.reduce(waiting.state, .regionCaptured(F.id, F.region)).get()
        #expect(
            generating.effects == [
                .generate(F.id, instruction: "Résume ce texte.", selection: F.selection, hasRegion: true)
            ])
        #expect(generating.state.context?.region == F.region)
    }

    @Test func askingWithoutTheFrameForgetsItAndTheFailedCall() throws {
        let retried = try reducer.reduce(F.regionAskFailed, .askRetryWithoutRegion(F.id)).get()
        #expect(retried.effects == [.generate(F.id, instruction: "Résume ce texte.", selection: F.selection)])
        #expect(retried.state.context?.region == nil && retried.state.context?.llmMs == nil)
        let fromDenied = try reducer.reduce(denied, .askRetryWithoutRegion(F.id)).get()
        #expect(fromDenied.state.context?.regionFailure == nil)
        #expect(fromDenied.state.ask?.stage == .generating)
    }
}

extension RegionTransitionTests {
    private func line(_ events: [PipelineEvent]) throws -> UtteranceRecord? {
        var state = PipelineState.idle
        var records: [UtteranceRecord] = []
        for event in events {
            guard case .success(let transition) = reducer.reduce(state, event) else { continue }
            state = transition.state
            records += transition.effects.compactMap(\.record)
        }
        #expect(records.count == 1)
        return records.first
    }

    private static func ask(_ intent: CaptureIntent, framed: Bool, withoutIt: Bool = false) -> [PipelineEvent] {
        let id = F.id
        var events: [PipelineEvent] = [.triggerDown(id, at: at, intent: intent)]
        if framed { events += [.regionStarted(id), .regionCaptured(id, F.region)] }
        events += [.triggerUp(at: at), .captured(id, F.speech), .transcribed(id, F.instruction, ms: 380)]
        if withoutIt {
            events += [
                .generationFailed(id, .noVision(model: F.bonsai, reason: .noVision), LLMCallSummary(ms: 40)),
                .askRetryWithoutRegion(id),
            ]
        }
        return events + [.generated(id, done, reply: "The answer."), .askCopy(id, F.answer), .copied(id)]
    }

    /// `context` names the kinds the last request carried: the selection when there was one, the frame when it went.
    @Test(
        arguments: [
            ("an ask about a selection", ask(F.ask, framed: false), "selection"),
            ("an ask about a selection, framed", ask(F.ask, framed: true), "selection+region"),
            ("the assistant, framed", ask(F.assist, framed: true), "region"),
            ("the assistant alone", ask(F.assist, framed: false), nil),
            ("framed, then asked without it", ask(F.ask, framed: true, withoutIt: true), "selection"),
            (
                "a dictation",
                [
                    .triggerDown(F.id, at: at), .focusCaptured(F.id, F.focus), .triggerUp(at: at),
                    .captured(F.id, F.speech), .transcribed(F.id, F.transcript, ms: 300),
                    .resolved(F.id, normalized: "open finder", .command(F.finder)), .actionFinished(F.id, exit: 0),
                ], nil
            ),
            ("an ask cancelled before its request", [.triggerDown(F.id, at: at, intent: F.ask), .cancel], nil),
        ] as [(String, [PipelineEvent], String?)])
    func theLineNamesTheContextSent(_ name: String, _ events: [PipelineEvent], _ kinds: String?) throws {
        let record = try #require(try line(events), "\(name)")
        #expect(record.context == kinds, "\(name)")
    }
}

// MARK: - M12: follow-ups in the Ask panel

private let pin = ProfilePin(
    name: "local", baseURL: URL(string: "http://127.0.0.1:8000/v1") ?? URL(fileURLWithPath: "/"), api: .openAI,
    model: .auto, requestedModel: F.bonsai)
private let pinned = LLMCallSummary(model: F.bonsai, ms: 2_610, finishReason: "stop", pin: pin)
private let followUpWords = Transcript(raw: "Plus court.", tier: .small)
private let reply1 = "Réunion jeudi 14 h : validation du budget T3."
private func uid(_ n: UInt64) -> UtteranceID { UtteranceID(n) }
private func pressAt(_ n: UInt64) -> Date { F.pressedAt.addingTimeInterval(Double(n)) }

/// Turn 1 in review, answered and pinned: what a first follow-up starts from.
private func reviewed(_ intent: CaptureIntent = F.ask, region: RegionSummary? = nil) -> PipelineState {
    var context = intent == F.ask ? F.askContext(llmModel: F.bonsai, llmMs: 2_610) : F.assistContext()
    context.llmModel = F.bonsai
    context.llmMs = 2_610
    context.reply = reply1
    context.pin = pin
    context.region = region
    return .asking(context, intent == F.ask ? F.instruction : F.request, .reviewing)
}

/// A turn in review whose thread already holds `answered` turns, the `framed` ones carrying a frame.
private func reviewedThread(answered: Int, framed: Set<Int> = [], region: RegionSummary? = nil) -> PipelineState {
    var thread = AskThread(rootID: uid(1), kind: .selection, selection: F.selectionText, pin: pin)
    for n in 0..<answered {
        thread = thread.appending(
            AskTurn(
                id: uid(UInt64(n) + 1), instruction: "Tour \(n)", reply: "Réponse \(n)",
                region: framed.contains(n) ? F.region : nil))
    }
    var context = UtteranceContext(
        id: uid(UInt64(answered) + 1), pressedAt: pressAt(UInt64(answered) + 1), intent: F.ask)
    context.focus = FocusSnapshot(app: F.textEdit)
    context.capture = F.speech
    context.llmModel = F.bonsai
    context.llmMs = 900
    context.reply = "Réponse courante"
    context.thread = answered == 0 ? nil : thread
    context.pin = pin
    context.region = region
    return .asking(context, followUpWords, .reviewing)
}

/// A follow-up's context, `new` pressed from `from`, at the given point of its capture.
private func followUpContext(
    from state: PipelineState = reviewed(), _ new: UInt64 = 2, released: Bool = true, captured: Bool = true
) -> UtteranceContext {
    guard case .success(let transition) = PipelineReducer().reduce(state, .followUpDown(uid(new), at: pressAt(new))),
        var context = transition.state.context
    else { return UtteranceContext(id: uid(new), pressedAt: pressAt(new)) }
    if released { context.releasedAt = pressAt(new).addingTimeInterval(1.5) }
    if captured { context.capture = F.speech }
    return context
}

private let followUpCapturing = PipelineState.capturing(followUpContext(released: false, captured: false))
private let followUpTranscribing = PipelineState.transcribing(followUpContext())
private func followUpAsking(_ stage: AskStage, pending: Bool = false, failure: RegionFailure? = nil) -> PipelineState {
    var context = followUpContext()
    context.regionPending = pending
    context.regionFailure = failure
    return .asking(context, followUpWords, stage)
}
/// A follow-up already sent: its parked turn is in the thread.
private func sentFollowUp(_ stage: AskStage) -> PipelineState {
    guard
        case .success(let transition) = PipelineReducer().reduce(
            followUpTranscribing, .transcribed(uid(2), followUpWords, ms: 300)),
        case .asking(let context, let transcript, _) = transition.state
    else { return .idle }
    return .asking(context, transcript, stage)
}

/// M12's rows. Their codes count for `everyFailureAndDiscardReasonIsCovered` through `askTransitions`.
let followUpTransitions: [LegalTransition] = [
    .init(
        name: "reviewing, follow-up: a new capture, no probe", state: reviewed(),
        event: .followUpDown(uid(2), at: pressAt(2)), phase: .capturing, effects: ["startCapture"]),
    .init(
        name: "reviewing an assistant answer, follow-up", state: reviewed(F.assist),
        event: .followUpDown(uid(2), at: pressAt(2)), phase: .capturing, effects: ["startCapture"]),
    .init(
        name: "reviewing with no pin and no thread, follow-up is busy", state: F.reviewing,
        event: .followUpDown(F.other, at: at), phase: .asking, effects: ["log:discarded:busy"]),
    .init(
        name: "reviewing turn 5, follow-up: turn 6", state: reviewedThread(answered: 4),
        event: .followUpDown(uid(9), at: pressAt(9)), phase: .capturing, effects: ["startCapture"]),
    .init(
        name: "reviewing turn 6, follow-up is busy", state: reviewedThread(answered: 5),
        event: .followUpDown(uid(9), at: pressAt(9)), phase: .asking, effects: ["log:discarded:busy"]),
    .init(
        name: "generating, follow-up is busy", state: F.generating, event: .followUpDown(F.other, at: at),
        phase: .asking, effects: ["log:discarded:busy"]),
    .init(
        name: "idle, follow-up is busy", state: .idle, event: .followUpDown(F.other, at: at), phase: .idle,
        effects: ["log:discarded:busy"]),
    .init(
        name: "a follow-up's capture, talk key is busy", state: followUpCapturing, event: .triggerDown(uid(3), at: at),
        phase: .capturing, effects: ["log:discarded:busy"]),
    .init(
        name: "a follow-up's capture, a second follow-up is busy", state: followUpCapturing,
        event: .followUpDown(uid(3), at: at), phase: .capturing, effects: ["log:discarded:busy"]),
    .init(
        name: "a follow-up's capture, Esc: the answer again", state: followUpCapturing, event: .cancel,
        phase: .asking, effects: ["cancelCapture", "log:discarded:cancelled"]),
    .init(
        name: "a follow-up's transcription, Esc: the answer again", state: followUpTranscribing, event: .cancel,
        phase: .asking, effects: ["cancelTranscription", "log:discarded:cancelled"]),
    .init(
        name: "a follow-up too short: the answer again",
        state: .transcribing(followUpContext(captured: false)), event: .captured(uid(2), F.short), phase: .asking,
        effects: ["log:discarded:too_short"]),
    .init(
        name: "a follow-up with no words: the answer again", state: followUpTranscribing,
        event: .transcribed(uid(2), Transcript(raw: " "), ms: 300), phase: .asking,
        effects: ["log:discarded:empty_transcript"]),
    .init(
        name: "a follow-up with words: the answer is superseded, the request leaves", state: followUpTranscribing,
        event: .transcribed(uid(2), followUpWords, ms: 300), phase: .asking,
        effects: ["log:discarded:followed_up", "generate"]),
    .init(
        name: "a follow-up waiting for its frame, Esc: the answer again",
        state: followUpAsking(.awaitingRegion, pending: true),
        event: .cancel, phase: .asking, effects: ["log:discarded:cancelled"]),
    .init(
        name: "a follow-up whose frame failed, Esc: the answer again",
        state: followUpAsking(.regionFailed(.captureFailed), failure: .captureFailed), event: .cancel,
        phase: .asking, effects: ["log:discarded:cancelled"]),
    .init(
        name: "a follow-up's capture fails: both lines",
        state: followUpCapturing, event: .failed(uid(2), .deviceChanged), phase: .idle,
        effects: ["cancelCapture", "log:failed:device_changed", "log:discarded:cancelled"]),
    .init(
        name: "a follow-up's transcription fails: both lines", state: followUpTranscribing,
        event: .failed(uid(2), .modelMissing(.small)), phase: .idle,
        effects: ["log:failed:model_missing:small", "log:discarded:cancelled"]),
    .init(
        name: "a follow-up's profile changed: the panel says so", state: sentFollowUp(.generating),
        event: .generationFailed(uid(2), .profileChanged, LLMCallSummary()), phase: .asking, effects: []),
    .init(
        name: "a follow-up's profile changed, cancel logs it", state: sentFollowUp(.failed(.profileChanged)),
        event: .cancel, phase: .idle, effects: ["log:failed:llm_profile_changed"]),
    .init(
        name: "a follow-up's answer, Copy", state: sentFollowUp(.reviewing), event: .askCopy(uid(2), F.answer),
        phase: .copying, effects: ["copyToClipboard"]),
    .init(
        name: "generating, an empty reply is llm_empty", state: F.generating,
        event: .generated(F.id, done, reply: " \n "), phase: .asking, effects: []),
]

/// The words of turn `n`, distinct per turn so a line can be checked for another turn's.
private func words(_ n: UInt64) -> Transcript { Transcript(raw: "Consigne numéro \(n) pour la suite.", tier: .small) }
private func replyOf(_ n: UInt64) -> String { "Réponse confidentielle \(n)." }

/// A follow-up `n` from an answer in review, said and heard: up to its transcript.
private func followUp(_ n: UInt64, _ transcript: Transcript? = nil) -> [PipelineEvent] {
    [
        .followUpDown(uid(n), at: pressAt(n)), .triggerUp(at: pressAt(n).addingTimeInterval(1.5)),
        .captured(uid(n), F.speech), .transcribed(uid(n), transcript ?? words(n), ms: 300),
    ]
}

/// Turn 1, a selection ask answered with a pin, then `count` follow-ups answered: the last in review.
private func conversation(_ intent: CaptureIntent = F.ask, followUps count: UInt64) -> [PipelineEvent] {
    var events: [PipelineEvent] = [
        .triggerDown(uid(1), at: pressAt(1), intent: intent), .triggerUp(at: pressAt(1).addingTimeInterval(1.5)),
        .captured(uid(1), F.speech), .transcribed(uid(1), words(1), ms: 300),
        .generated(uid(1), pinned, reply: replyOf(1)),
    ]
    guard count > 0 else { return events }
    for n in 2...(count + 1) {
        events += followUp(n) + [.generated(uid(n), done, reply: replyOf(n))]
    }
    return events
}

@Suite struct FollowUpTests {
    let reducer = PipelineReducer()

    /// Runs `events` from `state`, dropping rejected ones as the controller does.
    private func run(_ events: [PipelineEvent], from state: PipelineState = .idle) -> (
        state: PipelineState, effects: [PipelineEffect]
    ) {
        var state = state
        var effects: [PipelineEffect] = []
        for event in events {
            guard case .success(let transition) = reducer.reduce(state, event) else { continue }
            state = transition.state
            effects += transition.effects
        }
        return (state, effects)
    }

    @Test func aFollowUpTakesTheIntentFocusAndThreadAndParksTheAnswer() throws {
        let start = try reducer.reduce(reviewed(), .followUpDown(uid(2), at: pressAt(2))).get()
        #expect(start.effects == [.startCapture(uid(2))])
        let context = try #require(start.state.context)
        guard case .asking(let answered, let transcript, _) = reviewed() else { return }
        #expect(context.id == uid(2) && context.pressedAt == pressAt(2))
        #expect(context.intent == F.ask && context.focus == answered.focus)
        #expect(context.parked == .turn(answered, transcript))
        #expect(
            context.thread == AskThread(rootID: uid(1), kind: .selection, selection: F.selectionText, pin: pin))
        #expect(context.request == nil && context.region == nil && context.reply == nil && context.pin == nil)
        #expect(context.llmModel == nil && context.capture == nil && context.sentContext == nil)

        let assistant = try reducer.reduce(reviewed(F.assist), .followUpDown(uid(2), at: pressAt(2))).get()
        #expect(assistant.state.context?.thread?.kind == .assistant)
        #expect(assistant.state.context?.thread?.selection == nil)
    }

    @Test func aFourTurnThreadWritesOneLinePerTurn() throws {
        let end = run(conversation(followUps: 3) + [.askCopy(uid(4), F.answer), .copied(uid(4))])
        #expect(end.state == .idle)
        let records = end.effects.compactMap(\.record)
        #expect(records.map(\.timestamp) == (1...4).map { pressAt($0) })
        #expect(
            end.effects.compactMap { $0.record == nil ? nil : $0.label } == [
                "log:discarded:followed_up", "log:discarded:followed_up", "log:discarded:followed_up",
                "log:text_clipboard",
            ])
        for record in records { #expect(record.actionType == .ask) }
        for (n, record) in zip(UInt64(1)..., records) {
            #expect(record.rawText == words(n).raw)
            #expect(record.llmModel == F.bonsai && record.llmMs == 2_610)
        }
    }
}

extension FollowUpTests {
    /// The rules: no reply, no selection, and no other turn's instruction in any line of a thread.
    @Test func noLineOfAThreadHoldsAReplyTheSelectionOrAnotherTurn() {
        let end = run(conversation(followUps: 3) + [.askCopy(uid(4), F.answer), .copied(uid(4))])
        let records = end.effects.compactMap(\.record)
        #expect(records.count == 4)
        for (n, record) in zip(UInt64(1)..., records) {
            let line = record.jsonLine(timeZone: F.paris)
            for other in UInt64(1)...4 {
                #expect(!line.contains("confidentielle \(other)"), "\(line)")
                if other != n { #expect(!line.contains(words(other).raw), "\(line)") }
            }
            for word in ["comité", "budget", "Réunion", "validation"] { #expect(!line.contains(word), "\(line)") }
        }
    }

    @Test func theThreadHoldsEveryAnsweredTurn() throws {
        let end = run(conversation(followUps: 3))
        guard case .asking(let context, _, .reviewing) = end.state else {
            Issue.record("not reviewing")
            return
        }
        let thread = try #require(context.thread)
        #expect(thread.turns.map(\.id) == [uid(1), uid(2), uid(3)])
        #expect(thread.turns.map(\.instruction) == (1...3).map { words($0).raw })
        #expect(thread.turns.map(\.reply) == (1...3).map { replyOf($0) })
        #expect(context.reply == replyOf(4) && context.parked == nil && thread.pin == pin)
        #expect(context.conversationTurns == 4)
    }

    /// Esc, nothing heard and too short all bring back the answer the follow-up started from, whole.
    @Test(arguments: [
        ("Esc while capturing", [PipelineEvent.followUpDown(uid(9), at: pressAt(9)), .cancel], "cancelled"),
        (
            "Esc while transcribing",
            [.followUpDown(uid(9), at: pressAt(9)), .triggerUp(at: pressAt(10)), .cancel], "cancelled"
        ),
        (
            "too short",
            [.followUpDown(uid(9), at: pressAt(9)), .triggerUp(at: pressAt(10)), .captured(uid(9), F.short)],
            "too_short"
        ),
        ("nothing heard", followUp(9, Transcript(raw: " ")), "empty_transcript"),
    ])
    func aFollowUpWithNoWordsReturnsToTheAnswer(_ name: String, _ events: [PipelineEvent], _ code: String) {
        let reviewing = run(conversation(followUps: 1)).state
        let end = run(events, from: reviewing)
        #expect(end.state == reviewing, "\(name)")
        let records = end.effects.compactMap(\.record)
        #expect(records.count == 1 && records.first?.error == code && records.first?.context == nil)
        #expect(records.first?.timestamp == pressAt(9) && records.first?.actionType == .ask)
    }

    /// A follow-up that framed and then heard nothing: the answer comes back, the follow-up's frame is in no state.
    @Test func anEmptyFollowUpThatFramedReturnsWithoutItsFrame() {
        let reviewing = run(conversation(followUps: 1)).state
        let end = run(
            [
                .followUpDown(uid(9), at: pressAt(9)), .regionStarted(uid(9)), .regionCaptured(uid(9), F.region),
                .triggerUp(at: pressAt(10)), .captured(uid(9), F.speech),
                .transcribed(uid(9), Transcript(raw: " "), ms: 200),
            ], from: reviewing)
        #expect(end.state == reviewing)
        #expect(end.state.context?.region == nil && end.state.context?.thread?.framed == false)
    }

    /// Esc after the follow-up was heard, waiting for its frame or after it failed, still returns to the answer.
    @Test func escWaitingForTheFrameOrAfterItFailedReturnsToTheAnswer() {
        let reviewing = run(conversation(followUps: 1)).state
        let heard =
            [PipelineEvent.followUpDown(uid(9), at: pressAt(9)), .regionStarted(uid(9))] + followUp(9).dropFirst()
        let waiting = run(heard, from: reviewing)
        #expect(waiting.state.ask?.stage == .awaitingRegion && waiting.effects.compactMap(\.record).isEmpty)
        let cancelled = run([.cancel], from: waiting.state)
        #expect(cancelled.state == reviewing && cancelled.effects.map(\.label) == ["log:discarded:cancelled"])

        let failed = run([.regionFailed(uid(9), .captureFailed)], from: waiting.state)
        #expect(failed.state.ask?.stage == .regionFailed(.captureFailed))
        let back = run([.cancel], from: failed.state)
        #expect(back.state == reviewing && back.effects.map(\.label) == ["log:discarded:cancelled"])
    }
}

extension FollowUpTests {
    /// M11's region rows, applied to the follow-up's own turn; the parked answer's frame is never touched.
    @Test func aFollowUpFramesARegionOfItsOwn() throws {
        let other = RegionSummary(
            rect: F.region.rect, pixelWidth: 600, pixelHeight: 400, bytes: 90_000,
            displayID: 2)
        let reviewing = reviewed(region: F.region)
        var state = run([.followUpDown(uid(2), at: pressAt(2))], from: reviewing).state
        #expect(state.context?.region == nil)
        state = run([.regionStarted(uid(2))], from: state).state
        #expect(state.context?.regionPending == true)
        state = run([.regionCaptured(uid(2), other)], from: state).state
        #expect(state.context?.region == other && state.context?.regionPending == false)
        state = run([.regionStarted(uid(2)), .regionCaptured(uid(2), F.region)], from: state).state
        #expect(state.context?.region == F.region)
        state = run([.regionFailed(uid(2), .captureFailed)], from: state).state
        #expect(state.context?.regionFailure == .captureFailed)
        state = run([.regionRemoved(uid(2))], from: state).state
        #expect(state.context?.region == nil && state.context?.regionFailure == nil)
        guard case .asking(let answered, _, _) = reviewing else { return }
        #expect(state.context?.parked?.context == answered)
    }

    /// The frame cap counts the thread's frames and the parked turn's: a turn with none takes none, a re-drag is fine.
    @Test func atTheFrameCapATurnWithNoFrameTakesNone() throws {
        let full = reviewedThread(answered: 2, framed: [0, 1], region: F.region)
        let capturing = try reducer.reduce(full, .followUpDown(uid(9), at: pressAt(9))).get().state
        #expect(capturing.context?.earlierFrames == FrameTally(count: 3, bytes: 3 * F.region.bytes))
        #expect(capturing.context?.acceptsFrame == false)
        for event in [PipelineEvent.regionStarted(uid(9)), .regionCaptured(uid(9), F.region)] {
            #expect(reducer.reduce(capturing, event) == .failure(Rejection(phase: .capturing, event: event)))
        }

        // Two earlier frames: this turn takes a third, then may replace it.
        let room = reviewedThread(answered: 2, framed: [0], region: F.region)
        var state = try reducer.reduce(room, .followUpDown(uid(9), at: pressAt(9))).get().state
        state = run([.regionStarted(uid(9)), .regionCaptured(uid(9), F.region)], from: state).state
        #expect(state.context?.region == F.region && state.context?.acceptsFrame == true)
        let redrag = try reducer.reduce(state, .regionStarted(uid(9))).get().state
        #expect(redrag.context?.regionPending == true)
    }

    @Test func theFrameCapIsByBytesToo() throws {
        let heavy = RegionSummary(
            rect: F.region.rect, pixelWidth: 4000, pixelHeight: 3000, bytes: AskThread.maxFrameBytes, displayID: 1)
        var state = reviewed(region: heavy)
        state = try reducer.reduce(state, .followUpDown(uid(2), at: pressAt(2))).get().state
        #expect(state.context?.acceptsFrame == false)
        #expect(
            reducer.reduce(state, .regionStarted(uid(2)))
                == .failure(Rejection(phase: .capturing, event: .regionStarted(uid(2)))))
    }

    /// Six turns at most, the turn in review counted: five answered plus the one in review is full.
    @Test func theConversationHoldsSixTurns() throws {
        let sixth = run(conversation(followUps: 5)).state
        #expect(sixth.context?.conversationTurns == 6)
        let busy = try reducer.reduce(sixth, .followUpDown(uid(20), at: pressAt(20))).get()
        #expect(busy.state == sixth && busy.effects.map(\.label) == ["log:discarded:busy"])
        #expect(busy.effects.first?.record?.timestamp == pressAt(20))

        let fifth = run(conversation(followUps: 4)).state
        let capturing = try reducer.reduce(fifth, .followUpDown(uid(20), at: pressAt(20))).get().state
        #expect(capturing.phase == .capturing && capturing.context?.conversationTurns == 5)
    }

    @Test func aLongHistoryFillsTheConversation() throws {
        var state = reviewed()
        if case .asking(var context, let transcript, let stage) = state {
            context.reply = String(repeating: "x", count: AskThread.maxHistoryChars)
            state = .asking(context, transcript, stage)
        }
        let busy = try reducer.reduce(state, .followUpDown(uid(2), at: pressAt(2))).get()
        #expect(busy.state == state && busy.effects.map(\.label) == ["log:discarded:busy"])
    }
}

extension FollowUpTests {
    /// The parked answer is superseded once, when the request leaves: through a frame that arrives late, or Ask
    /// without the image after it failed. Retry never logs it again.
    @Test func theParkedLineIsWrittenOnceWhicheverRowFollows() throws {
        let reviewing = run(conversation(followUps: 0)).state
        let heard =
            [PipelineEvent.followUpDown(uid(2), at: pressAt(2)), .regionStarted(uid(2))] + followUp(2).dropFirst()
        let waiting = run(heard, from: reviewing)
        #expect(waiting.effects.map(\.label) == ["startCapture", "stopCapture", "transcribe"])

        let framed = run([.regionCaptured(uid(2), F.region)], from: waiting.state)
        #expect(framed.effects.map(\.label) == ["log:discarded:followed_up", "generate+region"])
        let failed = run([.regionFailed(uid(2), .captureFailed)], from: waiting.state)
        #expect(failed.effects.isEmpty)
        let without = run([.askRetryWithoutRegion(uid(2))], from: failed.state)
        #expect(without.effects.map(\.label) == ["log:discarded:followed_up", "generate"])

        let retried = run(
            [.generationFailed(uid(2), .noAnswer, LLMCallSummary(ms: 900)), .askRetry(uid(2))], from: framed.state)
        #expect(retried.effects.map(\.label) == ["generate+region"])
        #expect(retried.state.context?.thread == framed.state.context?.thread)
        #expect(retried.state.context?.thread?.turns.map(\.id) == [uid(1)])
    }

    /// Ask without the image drops this turn's frame only: an earlier turn's stays in the thread.
    @Test func askingWithoutTheImageDropsOnlyThisTurnsFrame() throws {
        var state = reviewedThread(answered: 1, framed: [0])
        state =
            run(
                [.followUpDown(uid(9), at: pressAt(9)), .regionStarted(uid(9)), .regionCaptured(uid(9), F.region)]
                    + followUp(9).dropFirst()
                    + [
                        .generationFailed(uid(9), .noVision(model: F.bonsai, reason: .noVision), LLMCallSummary(ms: 40))
                    ],
                from: state
            ).state
        let thread = try #require(state.context?.thread)
        let again = try reducer.reduce(state, .askRetryWithoutRegion(uid(9))).get()
        #expect(again.state.context?.region == nil && again.state.context?.thread == thread)
        #expect(thread.framed && thread.turns.count == 2)
        guard case .generate(_, _, _, let hasRegion, let sent) = again.effects.last else {
            Issue.record("no request")
            return
        }
        #expect(!hasRegion && sent == thread)
        #expect(again.state.context?.sentContext == "selection+region+history")
    }

    /// Quitting during a follow-up: the first cancel returns to the answer, the second ends it there. Two lines.
    @Test func quittingDuringAFollowUpLogsBothTurns() {
        let reviewing = run(conversation(followUps: 0)).state
        let end = run([.followUpDown(uid(2), at: pressAt(2)), .cancel, .cancel], from: reviewing)
        #expect(end.state == .idle)
        #expect(end.effects.compactMap(\.record).map(\.timestamp) == [pressAt(2), pressAt(1)])
        #expect(
            end.effects.map(\.label) == [
                "startCapture", "cancelCapture", "log:discarded:cancelled", "log:discarded:cancelled",
            ])
    }

    @Test func anEmptyReplyIsNoAnswerAndNeverATurn() throws {
        let generating = run(conversation(followUps: 0) + followUp(2)).state
        let empty = try reducer.reduce(generating, .generated(uid(2), done, reply: "  \n")).get()
        #expect(empty.state.ask?.stage == .failed(.empty) && empty.state.context?.reply == nil)
        #expect(empty.state.context?.llmModel == F.bonsai && empty.state.context?.llmMs == 2_610)
        let line = try #require(try reducer.reduce(empty.state, .cancel).get().effects.first?.record)
        #expect(line.error == "llm_empty")
        #expect(
            reducer.reduce(empty.state, .followUpDown(uid(3), at: pressAt(3))).map(\.state) == .success(empty.state))
    }
}

extension FollowUpTests {
    /// Replace on a later turn checks turn 1's selection, as turn 1 does.
    @Test func replaceOnTurnThreeIsGuardedByTurnOnesSelection() throws {
        let third = run(conversation(followUps: 2)).state
        let replacing = try reducer.reduce(third, .askReplace(uid(3), F.answer)).get()
        #expect(replacing.effects == [.checkSelection(uid(3), F.selection)])
        #expect(replacing.state.ask?.stage == .replacing)
    }

    /// A frame at any turn ends Replace for a selection thread from that turn on; Insert for the assistant stays.
    @Test func aFramedThreadIsNeverReplaced() throws {
        let second = run(conversation(followUps: 1)).state
        #expect(reducer.reduce(second, .askReplace(uid(2), F.answer)).map(\.state.phase) == .success(.asking))

        let framedNow = run(
            conversation(followUps: 1) + [
                .followUpDown(uid(3), at: pressAt(3)), .regionStarted(uid(3)),
                .regionCaptured(uid(3), F.region),
            ] + followUp(3).dropFirst()
                + [.generated(uid(3), done, reply: replyOf(3))]
        ).state
        #expect(framedNow.ask?.stage == .reviewing)
        let refused = PipelineEvent.askReplace(uid(3), F.answer)
        #expect(reducer.reduce(framedNow, refused) == .failure(Rejection(phase: .asking, event: refused)))

        let after = run([] + followUp(4) + [.generated(uid(4), done, reply: replyOf(4))], from: framedNow).state
        #expect(after.context?.region == nil && after.context?.thread?.framed == true)
        let later = PipelineEvent.askReplace(uid(4), F.answer)
        #expect(reducer.reduce(after, later) == .failure(Rejection(phase: .asking, event: later)))

        let turnOneFramed = reviewed(region: F.region)
        let first = PipelineEvent.askReplace(uid(1), F.answer)
        #expect(reducer.reduce(turnOneFramed, first) == .failure(Rejection(phase: .asking, event: first)))

        let assistant = reviewed(F.assist, region: F.region)
        let insert = try reducer.reduce(assistant, .askReplace(uid(1), F.answer)).get()
        #expect(insert.effects.map(\.label) == ["checkSelection"])
    }

    /// The line names the history a follow-up sent, and `region` once any turn framed, even one with no frame now.
    @Test(arguments: [
        ("history", CaptureIntent?.some(F.assist), false, false, "history"),
        ("selection+history", .some(F.ask), false, false, "selection+history"),
        ("region+history", .some(F.assist), true, false, "region+history"),
        ("selection+region+history", .some(F.ask), true, false, "selection+region+history"),
        ("region from an earlier turn", .some(F.assist), false, true, "region+history"),
        ("selection, region from an earlier turn", .some(F.ask), false, true, "selection+region+history"),
    ])
    func theLineNamesTheHistorySent(
        _ name: String, _ intent: CaptureIntent?, _ framesNow: Bool, _ framedBefore: Bool, _ kinds: String
    ) throws {
        let intent = intent ?? F.ask
        var events = conversation(intent, followUps: 0)
        if framedBefore {
            events =
                [
                    .triggerDown(uid(1), at: pressAt(1), intent: intent), .regionStarted(uid(1)),
                    .regionCaptured(uid(1), F.region),
                ] + events.dropFirst()
        }
        let frame: [PipelineEvent] = framesNow ? [.regionStarted(uid(2)), .regionCaptured(uid(2), F.region)] : []
        events +=
            [.followUpDown(uid(2), at: pressAt(2))] + frame + followUp(2).dropFirst()
            + [.generated(uid(2), done, reply: replyOf(2)), .askCopy(uid(2), F.answer), .copied(uid(2))]
        let records = run(events).effects.compactMap(\.record)
        #expect(records.count == 2, "\(name)")
        #expect(records.last?.context == kinds, "\(name)")
        #expect(
            records.first?.error == "followed_up"
                && records.first?.context
                    == (framedBefore
                        ? (intent == F.ask ? "selection+region" : "region") : (intent == F.ask ? "selection" : nil))
        )
    }
}
