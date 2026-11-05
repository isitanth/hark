import Foundation

public struct Transition: Sendable, Equatable {
    public var state: PipelineState
    public var effects: [PipelineEffect]

    public init(state: PipelineState, effects: [PipelineEffect]) {
        self.state = state
        self.effects = effects
    }
}

/// An event that is illegal in the current state, or addressed to an utterance that already ended.
/// The state is unchanged; the controller drops the event.
public struct Rejection: Error, Sendable, Equatable {
    public let phase: PipelinePhase
    public let event: PipelineEvent

    public init(phase: PipelinePhase, event: PipelineEvent) {
        self.phase = phase
        self.event = event
    }
}

/// The pipeline state machine. Pure: no clock, no I/O.
///
/// Invariant: every utterance gets exactly one `.writeLog`, emitted on the transition that ends it.
/// A press while busy is its own utterance and logs `discarded(busy)` without touching the current one.
public struct PipelineReducer: Sendable {
    public var policy: CapturePolicy
    /// Exact math (M13), stamped on each ask at its press. Off, every transition is today's.
    public var exactMath = false
    /// The user's format for an exact result (decision 8), set by the app through the controller. The default only
    /// keeps tests deterministic: nothing in HarkCore reads the Mac's locale.
    public var resultLocale = Locale(identifier: "en_US_POSIX")
    public var rounding = RoundingPolicy.standard
    /// The engine the `.planned` row calls: the reply, its finish reason, the sheet, the words and the conversation's
    /// kept results, to one outcome per result or a whole-reply failure (M14). Only tests set it. Until S2, the
    /// default wraps the one-result engine, and the row reads the first outcome.
    public typealias Solve =
        @Sendable (String, String?, CellSheet, String, [KeptResult]) -> Result<
            [ResultOutcome], MathFailure
        >
    public var solve: Solve = { reply, finish, sheet, instruction, kept in
        MathEngine.solveAll(reply: reply, finishReason: finish, sheet: sheet, instruction: instruction, kept: kept)
    }

    /// The result numbers the words name, given how many the conversation numbered (M14). Only tests set it.
    public var namedResults: @Sendable (String, Int) -> [Int] = { ResultWords.named(in: $0, count: $1) }

    /// The longest typed instruction (M15, decision 7): the field stops there; the reducer cuts as a safety net.
    public static let maxTypedCharacters = 4_000

    public init(policy: CapturePolicy = .standard) {
        self.policy = policy
    }

    public func reduce(_ state: PipelineState, _ event: PipelineEvent) -> Result<Transition, Rejection> {
        if case .triggerDown(let id, let at, let intent) = event {
            var context = UtteranceContext(id: id, pressedAt: at, intent: intent)
            // An ask knows its app already, and probing would find Hark: a Services call brings the provider forward.
            // The assistant is probed like a dictation: the Ask key leaves the caller in front, and whether a text
            // field has the focus decides whether Insert is offered.
            if case .ask(let selection) = intent { context.focus = FocusSnapshot(app: selection.caller) }
            if exactMath && intent.isAsk { context.math = ExactMathContext() }
            guard case .idle = state else {
                return .success(Transition(state: state, effects: [log(context, nil, .discarded(.busy))]))
            }
            guard case .ask(let selection) = intent else {
                return .success(Transition(state: .capturing(context), effects: [.startCapture(id), .probeFocus(id)]))
            }
            guard !selection.isBlank else {
                return .success(Transition(state: .idle, effects: [log(context, nil, .discarded(.emptySelection))]))
            }
            return .success(Transition(state: .capturing(context), effects: [.startCapture(id)]))
        }

        // A follow-up press carries a new id, like the talk key's: it is handled before the check that the event is
        // addressed to the current utterance.
        if case .followUpDown(let new, let at) = event { return followUp(state, new, at) }

        guard let context = state.context else { return reject(state, event) }
        if let target = event.utteranceID, target != context.id { return reject(state, event) }
        let id = context.id

        switch (state, event) {
        case (.capturing(var context), .focusCaptured(_, let focus)) where context.focus == nil:
            context.focus = focus
            return move(.capturing(context))

        case (.transcribing(var context), .focusCaptured(_, let focus)) where context.focus == nil:
            context.focus = focus
            return move(.transcribing(context))

        // A typed ask (M15) has no capture to stop: its zero summary would be discarded as too short and the words lost.
        case (.capturing(var context), .triggerUp(let at)) where context.input == .voice:
            context.releasedAt = at
            return move(.transcribing(context), [.stopCapture(id)])

        // The buffer is full: the capture ends here, the utterance does not. Stopping returns what was said until
        // now, with a summary that keeps the flag for the log line. The key is still held; its release lands in a
        // later state and is dropped. A limit that lands after the release is dropped too: the stop is already on
        // its way, and only its result carries the audio.
        case (.capturing(let context), .captureLimitReached) where context.input == .voice:
            return move(.transcribing(context), [.stopCapture(id)])

        // The first committed character (M15): the microphone stops and its samples are dropped, no transcription
        // runs, and the state stays `.capturing` so a frame can still be drawn.
        case (.capturing(var context), .typingStarted) where context.intent.isAsk && context.input == .voice:
            context.input = .typed
            return move(.capturing(context), [.cancelCapture(id)])

        // A typed instruction sent: the release is the submit, and the words take the spoken ask's path.
        case (.capturing(var context), .typed(_, let text, let at)) where context.input == .typed:
            context.releasedAt = at
            return askFromWords(context, Transcript(raw: String(text.prefix(Self.maxTypedCharacters)), tier: nil))

        case (.transcribing(var context), .captured(_, let summary)) where context.capture == nil:
            context.capture = summary
            if let reason = policy.discardReason(for: summary) {
                if let parked = context.parked { return returnToParked(context, parked, nil, .discarded(reason)) }
                return finish(context, nil, .discarded(reason))
            }
            return move(.transcribing(context), [.transcribe(id)])

        case (.transcribing(var context), .transcribed(_, let transcript, let ms)) where context.capture != nil:
            context.transcribeMs = ms
            // An ask known at the press branches here, not from `resolving` (the project rules): there is no command to match
            // and no destination to choose, and the normalized text for the log is a pure function. An ask found in
            // the words (M9's prefix, M10's routing) will branch from `resolving`.
            if context.intent.isAsk { return askFromWords(context, transcript) }
            if transcript.isBlank {
                if let parked = context.parked {
                    return returnToParked(context, parked, transcript, .discarded(.emptyTranscript))
                }
                return finish(context, transcript, .discarded(.emptyTranscript))
            }
            // Where the text goes, and whether it is a secret the log and the clipboard must not show, both come from
            // the focus. The probe always answers, within its AX timeouts, so a slow one is waited for.
            guard let focus = context.focus else { return move(.resolving(context, transcript)) }
            return move(.resolving(context, transcript), [.resolve(id, transcript, focus)])

        case (.resolving(var context, let transcript), .focusCaptured(_, let focus)) where context.focus == nil:
            context.focus = focus
            return move(.resolving(context, transcript), [.resolve(id, transcript, focus)])

        // The assistant's probe, answering after a short request was already heard: it still decides Insert.
        case (.asking(var context, let transcript, let stage), .focusCaptured(_, let focus)) where context.focus == nil:
            context.focus = focus
            return move(.asking(context, transcript, stage))

        case (.resolving(var context, var transcript), .resolved(_, let normalized, let decision)):
            transcript.normalized = normalized
            switch decision {
            case .command(let command):
                context.action = command.action
                if command.confirm {
                    return move(
                        .confirming(context, transcript, command, .awaitingAnswer), [.requestConfirmation(id, command)])
                }
                return move(.acting(context, transcript, command), [.runAction(id, command)])
            case .insert(let plan, let fallback):
                context.clipboardFallback = fallback
                return move(
                    .inserting(context, transcript, plan),
                    [.insert(id, text(context, transcript), plan, context.focus, clipboardFallback: fallback)])
            case .copy(let reason):
                return move(.copying(context, transcript, reason), [copy(context, transcript)])
            case .discard(let reason):
                return finish(context, transcript, .discarded(reason))
            // An ask found in the words branches here (the project rules): the dictation becomes the assistant, for the app it
            // was said in. The line keeps the whole transcript; the model gets what followed the prefix.
            // Text selected in that app makes it an ask about the text, with Replace, as the Ask key would.
            case .ask(let request, let selection):
                if let selection, !selection.isBlank {
                    context.intent = .ask(selection)
                } else {
                    context.intent = .assist(caller: context.focus?.app)
                }
                context.request = request
                let request = send(&context, transcript)
                return move(.asking(context, transcript, .generating), request)
            }

        case (.confirming(let context, let transcript, let command, .awaitingAnswer), .confirmed(_, let accepted)):
            guard accepted else { return finish(context, transcript, .discarded(.declined)) }
            return move(.confirming(context, transcript, command, .restoringFocus), [.restoreFocus(id, context.focus)])

        case (.confirming(let context, let transcript, let command, .restoringFocus), .focusRestored(_, let restored)):
            guard restored else { return finish(context, transcript, .failed(.focusNotRestored)) }
            return move(.acting(context, transcript, command), [.runAction(id, command)])

        case (.acting(let context, let transcript, _), .actionFinished(_, let exit)):
            return finish(context, transcript, exit == 0 ? .command : .failed(.actionExit(exit)))

        case (.inserting(let context, let transcript, _), .inserted):
            return finish(context, transcript, .textInserted)

        case (.inserting(let context, let transcript, _), .failed(_, let failure)):
            // With the fallback off the text is dropped rather than left on the clipboard: the line records the
            // setting that decided its fate, not the failure behind it, which is what the roadmap asks for. Every
            // insertion failure also writes an `insertion` os_log line, at error level when it leaves no other
            // trace.
            guard context.clipboardFallback else {
                return finish(context, transcript, .discarded(.clipboardFallbackDisabled))
            }
            return move(.copying(context, transcript, .fallback(failure)), [copy(context, transcript)])

        case (.copying(let context, let transcript, let reason), .copied):
            return finish(context, transcript, .textClipboard(reason))

        // The reply is kept for the history and the pin for a follow-up. An empty one is no answer: it never becomes a
        // turn, which the APIs would refuse.
        case (.asking(var context, let transcript, .generating), .generated(_, let summary, let reply)):
            context.llmModel = summary.model
            context.llmMs = summary.ms
            guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return move(.asking(context, transcript, .failed(.empty)))
            }
            context.reply = reply
            context.pin = summary.pin ?? context.pin
            return move(.asking(context, transcript, .reviewing))

        case (.asking(var context, let transcript, .generating), .generationFailed(_, let failure, let summary)):
            context.llmModel = summary.model
            context.llmMs = summary.ms
            return move(.asking(context, transcript, .failed(failure)))

        // The region events, while the request has not left. A new drag replaces the frame; the chip's × removes it.
        case (.capturing(let context), .regionStarted), (.capturing(let context), .regionCaptured),
            (.capturing(let context), .regionFailed), (.capturing(let context), .regionRemoved),
            (.capturing(let context), .regionAbandoned):
            guard let (context, reads) = framing(context, event) else { return reject(state, event) }
            return move(.capturing(context), reads)

        case (.transcribing(let context), .regionStarted), (.transcribing(let context), .regionCaptured),
            (.transcribing(let context), .regionFailed), (.transcribing(let context), .regionRemoved),
            (.transcribing(let context), .regionAbandoned):
            guard let (context, reads) = framing(context, event) else { return reject(state, event) }
            return move(.transcribing(context), reads)

        // The read runs while the user speaks: its result waits in the context for the words. A read superseded by a
        // re-drag or the chip's × is no longer pending, and its result is dropped.
        case (.capturing(var context), .regionRead(_, let sheet)) where context.math?.reading == .pending:
            context.math?.reading = .read(sheet)
            return move(.capturing(context))

        case (.capturing(var context), .regionReadFailed(_, let failure)) where context.math?.reading == .pending:
            context.math?.reading = .failed(failure)
            return move(.capturing(context))

        case (.transcribing(var context), .regionRead(_, let sheet)) where context.math?.reading == .pending:
            context.math?.reading = .read(sheet)
            return move(.transcribing(context))

        case (.transcribing(var context), .regionReadFailed(_, let failure)) where context.math?.reading == .pending:
            context.math?.reading = .failed(failure)
            return move(.transcribing(context))

        // The instruction is heard and waited for the frame: its capture sends the request, its failure stops it.
        case (.asking(let context, let transcript, .awaitingRegion), .regionStarted),
            (.asking(let context, let transcript, .awaitingRegion), .regionCaptured),
            (.asking(let context, let transcript, .awaitingRegion), .regionFailed),
            (.asking(let context, let transcript, .awaitingRegion), .regionRemoved),
            (.asking(let context, let transcript, .awaitingRegion), .regionAbandoned):
            guard let (context, reads) = framing(context, event) else { return reject(state, event) }
            if context.regionPending { return move(.asking(context, transcript, .awaitingRegion), reads) }
            if let failure = context.regionFailure {
                return move(.asking(context, transcript, .regionFailed(failure)), reads)
            }
            return route(context, transcript, reads: reads)

        // The failed call's numbers go: the line reports the call that ended the ask. The frame stays.
        case (.asking(var context, let transcript, .failed), .askRetry):
            context.llmModel = nil
            context.llmMs = nil
            // A plan the server failed is planned again, never answered freely.
            if context.math?.routed == true, case .read(let sheet) = context.math?.reading {
                let request = sendPlan(&context, transcript, sheet)
                return move(.asking(context, transcript, .planning), request)
            }
            let request = send(&context, transcript)
            return move(.asking(context, transcript, .generating), request)

        // Ask without the image: after a server failure (one that cannot read images) or a frame that failed.
        case (.asking(var context, let transcript, .failed), .askRetryWithoutRegion),
            (.asking(var context, let transcript, .regionFailed), .askRetryWithoutRegion):
            context.llmModel = nil
            context.llmMs = nil
            context.region = nil
            context.regionFailure = nil
            // The frame is gone, and the cells read from it with it: a later follow-up never plans over them.
            context.math?.reading = .idle
            context.math?.routed = false
            context.math?.clearResults()
            let request = send(&context, transcript)
            return move(.asking(context, transcript, .generating), request)

        // The reader answers while the instruction waits for it (M13).
        case (.asking(var context, let transcript, .reading), .regionRead(_, let sheet))
        where context.math?.reading == .pending:
            context.math?.reading = .read(sheet)
            guard sheet.hasAmount || namesResult(context, context.request ?? transcript.raw) else {
                return free(context, transcript)
            }
            let request = sendPlan(&context, transcript, sheet)
            return move(.asking(context, transcript, .planning), request)

        case (.asking(var context, let transcript, .reading), .regionReadFailed(_, let failure))
        where context.math?.reading == .pending:
            context.math?.reading = .failed(failure)
            return move(.asking(context, transcript, .mathFailed(.reader(failure))))

        // Let the model answer while the reader works: the user chose it, so nothing failed and `fallback` stays nil.
        case (.asking(var context, let transcript, .reading), .askWithoutExactMath):
            context.math?.reading = .idle
            context.math?.routed = false
            let request = send(&context, transcript)
            return move(.asking(context, transcript, .generating), [.cancelReading(id)] + request)

        // Let the model answer after the exact path failed: today's framed ask, its line reporting the free call and
        // the failure it replaced. From a reader failure no request has left yet, so the parked turn is superseded here.
        case (.asking(var context, let transcript, .mathFailed(let failure)), .askWithoutExactMath):
            context.llmModel = nil
            context.llmMs = nil
            context.math?.routed = false
            context.math?.clearResults()
            context.math?.fallback = failure.pipelineFailure
            let request = send(&context, transcript)
            return move(.asking(context, transcript, .generating), request)

        // The plan's stream ended: the engine decides. The line carries the plan calls' numbers, summed over a retry.
        case (.asking(var context, let transcript, .planning), .planned(_, let summary, let reply)):
            guard var math = context.math, case .read(let sheet) = math.reading else { return reject(state, event) }
            context.llmMs = Self.sum(context.llmMs, summary.ms)
            context.llmModel = summary.model ?? context.llmModel
            let instruction = context.request ?? transcript.raw
            let solved = solve(reply, summary.finishReason, sheet, instruction, context.keptResults)
            if math.attempts == 1, let note = PlanPrompt.retryNote(solved) {
                math.attempts = 2
                context.math = math
                let request = plan(&context, transcript, sheet, correction: PlanCorrection(reply: reply, note: note))
                return move(.asking(context, transcript, .planning), [request])
            }
            switch solved {
            case .success(let outcomes) where outcomes.contains(where: { (try? $0.get()) != nil }):
                let numbers = outcomes.indices.map { context.nextResultNumber + $0 }
                let answers = outcomes.map { outcome in
                    outcome.map {
                        ExactAnswer(
                            $0, sheet: sheet, policy: rounding, fallback: resultLocale, kept: context.keptResults)
                    }
                }
                math.results = outcomes
                math.numbers = numbers
                math.kept = zip(numbers, zip(outcomes, answers)).compactMap { number, pair in
                    guard case .success(let computation) = pair.0, case .success(let answer) = pair.1 else {
                        return nil
                    }
                    return KeptResult(
                        number: number, computation: computation, answer: answer, sheet: sheet, policy: rounding,
                        turn: id)
                }
                // A failed result keeps its `understood` ([SETTLED] 2): it comes from the plan, one per result.
                let plans = (try? PlanSet.decode(reply, finishReason: summary.finishReason).get())?.results ?? []
                math.understoods = answers.enumerated().map { index, answer in
                    index < plans.count ? plans[index].understood : ((try? answer.get())?.understood ?? "")
                }
                context.math = math
                let composed = PlanPrompt.composedReply(
                    zip(numbers, zip(answers, math.understoods)).map { number, pair in
                        PlanPrompt.ComposedResult(number: number, understood: pair.1, answer: try? pair.0.get())
                    })
                context.reply = composed
                context.pin = summary.pin ?? context.pin
                return move(.asking(context, transcript, .reviewing), [.publishAnswer(id, composed)])
            case .success(let outcomes):
                // Every result failed: the first failure is the turn's, as one result's was in 0.1.0.
                let failure =
                    outcomes.lazy.compactMap { outcome -> MathFailure? in
                        if case .failure(let failure) = outcome { return failure }
                        return nil
                    }.first ?? .plan(.json)
                context.math = math
                return move(.asking(context, transcript, .mathFailed(failure)))
            case .failure(let failure):
                context.math = math
                return move(.asking(context, transcript, .mathFailed(failure)))
            }

        case (.asking(var context, let transcript, .planning), .generationFailed(_, let failure, let summary)):
            context.llmModel = summary.model ?? context.llmModel
            context.llmMs = Self.sum(context.llmMs, summary.ms)
            return move(.asking(context, transcript, .failed(failure)))

        // The user chose the clipboard: `chosen`, so the line's error is null.
        case (.asking(var context, let transcript, .reviewing), .askCopy(_, let text)):
            context.answer = text
            return move(.copying(context, transcript, .chosen), [copy(context, transcript)])

        // Replace for an ask, Insert for the assistant: both write where the caller's selection is, so both check first
        // that it is still the one the press saw, the text asked about or nothing selected.
        case (.asking(var context, let transcript, .reviewing), .askReplace(_, let text)):
            guard var expected = context.intent.expectedSelection else { return reject(state, event) }
            // An image has no text to replace: once a turn of the conversation is framed, a selection is not replaced.
            if case .ask = context.intent, context.region != nil || context.thread?.framed == true {
                return reject(state, event)
            }
            // An Ask key pressed with no app known: the probe's app is the one Insert writes into.
            if expected.caller == nil { expected.caller = context.focus?.app }
            context.answer = text
            return move(.asking(context, transcript, .replacing), [.checkSelection(id, expected)])

        // Intact, the answer goes in as a dictation would, through the same inserter and its fallbacks. Otherwise it is
        // kept on the clipboard, never written over text the user did not ask about; the line stays the caller's.
        case (.asking(var context, let transcript, .replacing), .selectionChecked(_, let check)):
            guard check.verdict == .intact else {
                return move(
                    .copying(context, transcript, .fallback(.selectionChanged)), [copy(context, transcript)])
            }
            context.focus = check.focus
            guard let plan = check.plan else {
                let reason: ClipboardReason = check.focus.isSecureInput ? .secureField : .noTextField
                return move(.copying(context, transcript, reason), [copy(context, transcript)])
            }
            context.clipboardFallback = true
            return move(
                .inserting(context, transcript, plan),
                [.insert(id, text(context, transcript), plan, context.focus, clipboardFallback: true)])

        // The engine may still be running (cap reached, converter error): release the microphone. A typed ask (M15)
        // has cancelled its capture: a late audio failure (a slow Bluetooth start, an interruption already queued) is
        // no longer its, and its typed words stay.
        case (.capturing(let context), .failed(_, let failure)) where context.input == .voice:
            return finishFollowUp(context, nil, .failed(failure), cleanup: [.cancelCapture(id)])

        case (.transcribing(let context), .failed(_, let failure))
        where context.capture == nil || !failure.isCaptureFailure:
            return finishFollowUp(context, nil, .failed(failure))

        case (.acting(let context, let transcript, _), .failed(_, let failure)),
            (.copying(let context, let transcript, _), .failed(_, let failure)):
            return finish(context, transcript, .failed(failure))

        // Esc before a follow-up's request leaves returns to the answer it started from.
        case (.capturing(let context), .cancel):
            if let parked = context.parked {
                return returnToParked(context, parked, nil, .discarded(.cancelled), cleanup: [.cancelCapture(id)])
            }
            return finish(context, nil, .discarded(.cancelled), cleanup: [.cancelCapture(id)])

        case (.transcribing(let context), .cancel):
            let cleanup: PipelineEffect = context.capture == nil ? .cancelCapture(id) : .cancelTranscription(id)
            if let parked = context.parked {
                return returnToParked(context, parked, nil, .discarded(.cancelled), cleanup: [cleanup])
            }
            return finish(context, nil, .discarded(.cancelled), cleanup: [cleanup])

        case (.resolving(let context, let transcript), .cancel):
            return finish(context, transcript, .discarded(.cancelled))

        case (.confirming(let context, let transcript, _, let stage), .cancel):
            let cleanup: [PipelineEffect] = stage == .awaitingAnswer ? [.dismissConfirmation(id)] : []
            return finish(context, transcript, .discarded(.cancelled), cleanup: cleanup)

        // Before the request leaves, Esc in a follow-up returns to the answer it started from.
        case (.asking(let context, let transcript, .reading), .cancel):
            if let parked = context.parked {
                return returnToParked(
                    context, parked, transcript, .discarded(.cancelled), cleanup: [.cancelReading(id)])
            }
            return finish(context, transcript, .discarded(.cancelled), cleanup: [.cancelReading(id)])

        case (.asking(let context, let transcript, .mathFailed(let failure)), .cancel):
            if let parked = context.parked {
                return returnToParked(context, parked, transcript, .discarded(.cancelled))
            }
            return finish(context, transcript, .failed(failure.pipelineFailure))

        case (.asking(let context, let transcript, .generating), .cancel),
            (.asking(let context, let transcript, .planning), .cancel):
            return finish(context, transcript, .discarded(.cancelled), cleanup: [.cancelGeneration(id)])

        // The panel's Cancel, or quitting: the conversation ends on this answer.
        case (.asking(let context, let transcript, .reviewing), .cancel),
            (.asking(let context, let transcript, .replacing), .cancel):
            return finish(context, transcript, .discarded(.cancelled))

        case (.asking(let context, let transcript, .awaitingRegion), .cancel):
            if let parked = context.parked {
                return returnToParked(context, parked, transcript, .discarded(.cancelled))
            }
            return finish(context, transcript, .discarded(.cancelled))

        // Closing the popup on an error is not the user giving up on a good answer: the line keeps what failed.
        case (.asking(let context, let transcript, .failed(let failure)), .cancel):
            return finish(context, transcript, .failed(failure.pipelineFailure))

        case (.asking(let context, let transcript, .regionFailed(let failure)), .cancel):
            if let parked = context.parked {
                return returnToParked(context, parked, transcript, .discarded(.cancelled))
            }
            return finish(context, transcript, .failed(failure.pipelineFailure))

        default:
            return reject(state, event)
        }
    }

    /// A follow-up from the answer in review (M12): a new capture, the answer parked until the follow-up has words.
    /// Anywhere else, or with the conversation full, the press is busy. Nothing reaches the engine without a pin.
    private func followUp(_ state: PipelineState, _ new: UtteranceID, _ at: Date) -> Result<Transition, Rejection> {
        let intent = state.context?.intent ?? .assist(caller: nil)
        let busy = Transition(
            state: state,
            effects: [log(UtteranceContext(id: new, pressedAt: at, intent: intent), nil, .discarded(.busy))])
        guard case .asking(let context, let transcript, .reviewing) = state,
            !context.conversationFull(instruction: context.request ?? transcript.raw)
        else { return .success(busy) }
        let thread: AskThread
        if let kept = context.thread {
            thread = kept
        } else if let pin = context.pin {
            let selection = context.intent.selection
            thread = AskThread(
                rootID: context.id, kind: selection == nil ? .assistant : .selection, selection: selection?.text,
                pin: pin)
        } else {
            return .success(busy)
        }
        var next = UtteranceContext(id: new, pressedAt: at, intent: context.intent)
        next.focus = context.focus
        next.thread = thread
        next.parked = .turn(context, transcript)
        if exactMath { next.math = ExactMathContext() }
        return move(.capturing(next), [.startCapture(new)])
    }

    /// A follow-up that ends before its request leaves: Esc, nothing heard, too short. Its own line, then the answer it
    /// started from is in review again. A frame it brought is no longer in the state.
    private func returnToParked(
        _ context: UtteranceContext, _ parked: ParkedTurn, _ transcript: Transcript?, _ outcome: PipelineOutcome,
        cleanup: [PipelineEffect] = []
    ) -> Result<Transition, Rejection> {
        move(
            .asking(parked.context, parked.transcript, .reviewing), cleanup + [log(context, transcript, outcome)])
    }

    /// A follow-up that ends any other way before its request leaves: its line, and the parked turn's, so no answered
    /// turn goes unlogged.
    private func finishFollowUp(
        _ context: UtteranceContext, _ transcript: Transcript?, _ outcome: PipelineOutcome,
        cleanup: [PipelineEffect] = []
    ) -> Result<Transition, Rejection> {
        var effects = cleanup + [log(context, transcript, outcome)]
        if let parked = context.parked {
            effects.append(log(parked.context, parked.transcript, .discarded(.cancelled)))
        }
        return .success(Transition(state: .idle, effects: effects))
    }

    /// The request leaving. A follow-up's parked turn is superseded here, once: its line says `followed_up` and it
    /// joins the thread, so the request carries it as history. Until then Esc can still return to it.
    private func send(_ context: inout UtteranceContext, _ transcript: Transcript) -> [PipelineEffect] {
        supersede(&context) + [generate(&context, transcript)]
    }

    /// The exact twin of `send`: the parked turn superseded, then the plan over `sheet`, first attempt.
    private func sendPlan(_ context: inout UtteranceContext, _ transcript: Transcript, _ sheet: CellSheet)
        -> [PipelineEffect]
    {
        context.math?.routed = true
        context.math?.attempts = 1
        context.math?.reading = .read(sheet)
        return supersede(&context) + [plan(&context, transcript, sheet, correction: nil)]
    }

    /// The parked turn joins the thread with its `followed_up` line. An exact turn keeps its sheet and formula, and its
    /// reply is the one Hark composed; a free turn's stay nil.
    private func supersede(_ context: inout UtteranceContext) -> [PipelineEffect] {
        guard let parked = context.parked, let thread = context.thread else { return [] }
        let turn = parked.context
        var sheet: CellSheet?
        var formulas: [String] = []
        var results: [KeptResult] = []
        var numbers: [Int] = []
        if let math = turn.math, let computation = math.computation, case .read(let read) = math.reading {
            sheet = read
            let computed = math.results.compactMap { try? $0.get() }
            formulas = (computed.isEmpty ? [computation] : computed).map(\.plan.formula)
            results = math.kept
            numbers = math.numbers
        }
        context.thread = thread.appending(
            AskTurn(
                id: turn.id, instruction: turn.request ?? parked.transcript.raw, reply: turn.reply ?? "",
                region: turn.region, sheet: sheet, formula: formulas.first, formulas: formulas, results: results,
                numbers: numbers))
        context.parked = nil
        return [log(turn, parked.transcript, .discarded(.followedUp))]
    }

    /// Where an exact ask goes once its words are known (M13). Routed: a frame, or in a follow-up with none of its own
    /// the conversation's latest sheet, and words that ask for a calculation. Anything else is today's ask, byte for
    /// byte. `reads` are the effects of a frame captured at this very event: the read starts only when it is needed.
    private func route(_ context: UtteranceContext, _ transcript: Transcript, reads: [PipelineEffect] = [])
        -> Result<Transition, Rejection>
    {
        var context = context
        guard let math = context.math else { return free(context, transcript) }
        let instruction = context.request ?? transcript.raw
        let earlier = context.region == nil ? Self.latestSheet(context) : nil
        let named = namesResult(context, instruction)
        guard context.region != nil || earlier != nil, named || MathIntent.isComputation(instruction) else {
            return free(context, transcript)
        }
        // A named result is worth a plan over any sheet: the formula may read the result alone.
        if let earlier {
            guard earlier.hasAmount || named else { return free(context, transcript) }
            let request = sendPlan(&context, transcript, earlier)
            return move(.asking(context, transcript, .planning), request)
        }
        switch math.reading {
        case .read(let sheet) where sheet.hasAmount || named:
            let request = sendPlan(&context, transcript, sheet)
            return move(.asking(context, transcript, .planning), request)
        case .pending:
            context.math?.routed = true
            return move(.asking(context, transcript, .reading), reads)
        case .failed(let failure):
            context.math?.routed = true
            return move(.asking(context, transcript, .mathFailed(.reader(failure))))
        case .read, .idle:
            return free(context, transcript)
        }
    }

    /// Today's ask. A read still running is no longer waited for: the controller cancels it.
    private func free(_ context: UtteranceContext, _ transcript: Transcript) -> Result<Transition, Rejection> {
        var context = context
        if context.math?.reading == .pending { context.math?.reading = .idle }
        context.math?.routed = false
        let request = send(&context, transcript)
        return move(.asking(context, transcript, .generating), request)
    }

    /// Whether the words name a result the conversation keeps (M14, plan §4.3): such a follow-up goes to the exact path
    /// past the frozen word check, its block list still winning (« explique le résultat 2 » stays a free ask).
    private func namesResult(_ context: UtteranceContext, _ instruction: String) -> Bool {
        guard !context.keptResults.isEmpty else { return false }
        let named = namedResults(instruction, context.nextResultNumber - 1)
        return !named.isEmpty && !Self.blocked(instruction)
    }

    /// `MathIntent`'s block list over the words, its fillers taken out first, as `isComputation` reads them.
    private static func blocked(_ instruction: String) -> Bool {
        var question = MathIntent.normalize(instruction)
        for filler in MathIntent.fillers {
            question = question.replacingOccurrences(of: MathIntent.normalize(filler), with: " ")
        }
        return MathIntent.hits(question, MathIntent.blockEnglish) || MathIntent.hits(question, MathIntent.blockFrench)
    }

    /// A follow-up with no frame of its own computes over the conversation's latest sheet: the parked turn's, which
    /// joins the thread only when superseded, else the thread's last.
    private static func latestSheet(_ context: UtteranceContext) -> CellSheet? {
        if case .read(let sheet) = context.parked?.context.math?.reading { return sheet }
        return context.thread?.turns.last { $0.sheet != nil }?.sheet
    }

    /// The plan request. Its context kinds are written in a fixed order: selection, region, cells, history.
    private func plan(
        _ context: inout UtteranceContext, _ transcript: Transcript, _ sheet: CellSheet, correction: PlanCorrection?
    ) -> PipelineEffect {
        let selection = context.intent.selection.flatMap { $0.isBlank ? nil : $0 }
        let thread = context.thread
        let kinds: [String?] = [
            selection != nil || thread?.selection != nil ? "selection" : nil,
            context.region != nil || thread?.framed == true ? "region" : nil,
            "cells",
            thread != nil ? "history" : nil,
        ]
        context.sentContext = kinds.compactMap(\.self).joined(separator: "+")
        return .plan(
            context.id, instruction: context.request ?? transcript.raw, sheet: sheet,
            selection: context.intent.selection, thread: thread, correction: correction)
    }

    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        guard a != nil || b != nil else { return nil }
        return (a ?? 0) + (b ?? 0)
    }

    /// The request: what followed a spoken prefix, or the transcript; the image when a frame was captured. The context
    /// remembers the kinds it carried, for the line.
    private func generate(_ context: inout UtteranceContext, _ transcript: Transcript) -> PipelineEffect {
        let selection = context.intent.selection.flatMap { $0.isBlank ? nil : $0 }
        let thread = context.thread
        let kinds: [String?] = [
            selection != nil || thread?.selection != nil ? "selection" : nil,
            context.region != nil || thread?.framed == true ? "region" : nil,
            thread != nil ? "history" : nil,
        ]
        let named = kinds.compactMap(\.self)
        context.sentContext = named.isEmpty ? nil : named.joined(separator: "+")
        return .generate(
            context.id, instruction: context.request ?? transcript.raw, selection: context.intent.selection,
            hasRegion: context.region != nil, thread: thread)
    }

    /// A region event, and for an exact ask the read it starts or stops: a captured frame is read at once, while the
    /// user speaks; a new drag or the chip's × drops a read under way, and a drag abandoned over a frame captured before
    /// it reads that frame again.
    private func framing(_ context: UtteranceContext, _ event: PipelineEvent)
        -> (UtteranceContext, [PipelineEffect])?
    {
        guard var context = region(context, event) else { return nil }
        guard let math = context.math else { return (context, []) }
        let stop: [PipelineEffect] = math.reading == .pending ? [.cancelReading(context.id)] : []
        switch event {
        case .regionCaptured:
            context.math?.reading = .pending
            return (context, stop + [.readRegion(context.id)])
        case .regionStarted, .regionRemoved:
            context.math?.reading = .idle
            return (context, stop)
        case .regionAbandoned where context.region != nil && math.reading == .idle:
            context.math?.reading = .pending
            return (context, [.readRegion(context.id)])
        default:
            return (context, [])
        }
    }

    /// A region event applied to an ask's context; nil for a dictation, which frames nothing.
    private func region(_ context: UtteranceContext, _ event: PipelineEvent) -> UtteranceContext? {
        guard context.intent.isAsk else { return nil }
        // At a conversation's frame cap, a turn with no frame of its own takes none; a drag replacing its frame is fine.
        switch event {
        case .regionStarted, .regionCaptured: guard context.acceptsFrame else { return nil }
        default: break
        }
        var context = context
        switch event {
        case .regionStarted:
            context.regionPending = true
            context.regionFailure = nil
        case .regionCaptured(_, let summary):
            context.region = summary
            context.regionPending = false
            context.regionFailure = nil
        case .regionFailed(_, let failure):
            context.regionPending = false
            context.regionFailure = failure
        case .regionRemoved:
            context.region = nil
            context.regionFailure = nil
        case .regionAbandoned:
            context.regionPending = false
        default:
            return nil
        }
        return context
    }

    private func copy(_ context: UtteranceContext, _ transcript: Transcript) -> PipelineEffect {
        .copyToClipboard(context.id, text(context, transcript), concealed: context.focus?.isSecureInput ?? false)
    }

    /// What reaches the field or the clipboard: an ask's answer, or what was said.
    private func text(_ context: UtteranceContext, _ transcript: Transcript) -> String {
        context.answer ?? transcript.raw
    }

    private func move(_ state: PipelineState, _ effects: [PipelineEffect] = []) -> Result<Transition, Rejection> {
        .success(Transition(state: state, effects: effects))
    }

    private func finish(
        _ context: UtteranceContext, _ transcript: Transcript?, _ outcome: PipelineOutcome,
        cleanup: [PipelineEffect] = []
    ) -> Result<Transition, Rejection> {
        .success(Transition(state: .idle, effects: cleanup + [log(context, transcript, outcome)]))
    }

    private func log(_ context: UtteranceContext, _ transcript: Transcript?, _ outcome: PipelineOutcome)
        -> PipelineEffect
    {
        .writeLog(UtteranceRecord(context: context, transcript: transcript, outcome: outcome))
    }

    private func reject(_ state: PipelineState, _ event: PipelineEvent) -> Result<Transition, Rejection> {
        .failure(Rejection(phase: state.phase, event: event))
    }
}

// M15: the words of an ask, spoken (`.transcribed`) or typed (`.typed`), take one path from here.
extension PipelineReducer {
    /// The ask's branch from its words: a blank instruction is discarded, or returns a follow-up to its parked turn; a
    /// drag still open waits for its capture; a frame that failed ends the request before it leaves; else `route`.
    /// The caller has set `transcribeMs` (spoken) or `releasedAt` (typed).
    func askFromWords(_ context: UtteranceContext, _ transcript: Transcript) -> Result<Transition, Rejection> {
        if transcript.isBlank {
            if let parked = context.parked {
                return returnToParked(context, parked, transcript, .discarded(.emptyTranscript))
            }
            return finish(context, transcript, .discarded(.emptyTranscript))
        }
        var instruction = transcript
        instruction.normalized = Normalizer.normalize(transcript.raw)
        if context.regionPending { return move(.asking(context, instruction, .awaitingRegion)) }
        if let failure = context.regionFailure {
            return move(.asking(context, instruction, .regionFailed(failure)))
        }
        return route(context, instruction)
    }
}

// M14: the kept results of a plan of one to three results. The retry note and the composed reply are `PlanPrompt`'s.
extension KeptResult {
    /// A result as the panel showed it (plan §4.2): its exact value, its displayed unit and label, its decimals.
    init(
        number: Int, computation: Computation, answer: ExactAnswer, sheet: CellSheet, policy: RoundingPolicy,
        turn: UtteranceID
    ) {
        let plan = computation.plan
        let unit = RoundingPolicy.displayUnit(computation.unit, declared: plan.unit, value: computation.value)
        let shownValue = policy.round(computation.value, unit: unit, read: computation.read, sheet: sheet)
        let scale =
            policy.decimals(for: unit, read: computation.read, sheet: sheet)?.maximum
            ?? max(0, -Int(shownValue.exponent))
        self.init(
            number: number, value: computation.value, unit: unit,
            unitLabel: UnitLabel.kept(plan.unitLabel, computation: computation, sheet: sheet), scale: scale,
            shown: answer.result, understood: plan.understood, turn: turn)
    }
}
