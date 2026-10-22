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

        case (.capturing(var context), .triggerUp(let at)):
            context.releasedAt = at
            return move(.transcribing(context), [.stopCapture(id)])

        // The buffer is full: the capture ends here, the utterance does not. Stopping returns what was said until
        // now, with a summary that keeps the flag for the log line. The key is still held; its release lands in a
        // later state and is dropped. A limit that lands after the release is dropped too: the stop is already on
        // its way, and only its result carries the audio.
        case (.capturing(let context), .captureLimitReached):
            return move(.transcribing(context), [.stopCapture(id)])

        case (.transcribing(var context), .captured(_, let summary)) where context.capture == nil:
            context.capture = summary
            if let reason = policy.discardReason(for: summary) {
                if let parked = context.parked { return returnToParked(context, parked, nil, .discarded(reason)) }
                return finish(context, nil, .discarded(reason))
            }
            return move(.transcribing(context), [.transcribe(id)])

        case (.transcribing(var context), .transcribed(_, let transcript, let ms)) where context.capture != nil:
            context.transcribeMs = ms
            if transcript.isBlank {
                if let parked = context.parked {
                    return returnToParked(context, parked, transcript, .discarded(.emptyTranscript))
                }
                return finish(context, transcript, .discarded(.emptyTranscript))
            }
            // An ask known at the press branches here, not from `resolving` (the project rules): there is no command to match
            // and no destination to choose, and the normalized text for the log is a pure function. An ask found in
            // the words (M9's prefix, M10's routing) will branch from `resolving`.
            // A drag still open waits for its capture; a frame that failed ends the request before it leaves.
            if context.intent.isAsk {
                var instruction = transcript
                instruction.normalized = Normalizer.normalize(transcript.raw)
                if context.regionPending { return move(.asking(context, instruction, .awaitingRegion)) }
                if let failure = context.regionFailure {
                    return move(.asking(context, instruction, .regionFailed(failure)))
                }
                let request = send(&context, instruction)
                return move(.asking(context, instruction, .generating), request)
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
            guard let context = region(context, event) else { return reject(state, event) }
            return move(.capturing(context))

        case (.transcribing(let context), .regionStarted), (.transcribing(let context), .regionCaptured),
            (.transcribing(let context), .regionFailed), (.transcribing(let context), .regionRemoved),
            (.transcribing(let context), .regionAbandoned):
            guard let context = region(context, event) else { return reject(state, event) }
            return move(.transcribing(context))

        // The instruction is heard and waited for the frame: its capture sends the request, its failure stops it.
        case (.asking(let context, let transcript, .awaitingRegion), .regionStarted),
            (.asking(let context, let transcript, .awaitingRegion), .regionCaptured),
            (.asking(let context, let transcript, .awaitingRegion), .regionFailed),
            (.asking(let context, let transcript, .awaitingRegion), .regionRemoved),
            (.asking(let context, let transcript, .awaitingRegion), .regionAbandoned):
            guard var context = region(context, event) else { return reject(state, event) }
            if context.regionPending { return move(.asking(context, transcript, .awaitingRegion)) }
            if let failure = context.regionFailure {
                return move(.asking(context, transcript, .regionFailed(failure)))
            }
            let request = send(&context, transcript)
            return move(.asking(context, transcript, .generating), request)

        // The failed call's numbers go: the line reports the call that ended the ask. The frame stays.
        case (.asking(var context, let transcript, .failed), .askRetry):
            context.llmModel = nil
            context.llmMs = nil
            let request = send(&context, transcript)
            return move(.asking(context, transcript, .generating), request)

        // Ask without the image: after a server failure (one that cannot read images) or a frame that failed.
        case (.asking(var context, let transcript, .failed), .askRetryWithoutRegion),
            (.asking(var context, let transcript, .regionFailed), .askRetryWithoutRegion):
            context.llmModel = nil
            context.llmMs = nil
            context.region = nil
            context.regionFailure = nil
            let request = send(&context, transcript)
            return move(.asking(context, transcript, .generating), request)

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

        // The engine may still be running (cap reached, converter error): release the microphone.
        case (.capturing(let context), .failed(_, let failure)):
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

        case (.asking(let context, let transcript, .generating), .cancel):
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
        var effects: [PipelineEffect] = []
        if let parked = context.parked, let thread = context.thread {
            let turn = parked.context
            effects.append(log(turn, parked.transcript, .discarded(.followedUp)))
            context.thread = thread.appending(
                AskTurn(
                    id: turn.id, instruction: turn.request ?? parked.transcript.raw, reply: turn.reply ?? "",
                    region: turn.region))
            context.parked = nil
        }
        return effects + [generate(&context, transcript)]
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
