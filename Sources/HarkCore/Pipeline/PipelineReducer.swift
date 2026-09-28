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
        if case .triggerDown(let id, let at) = event {
            let context = UtteranceContext(id: id, pressedAt: at)
            guard case .idle = state else {
                return .success(Transition(state: state, effects: [log(context, nil, .discarded(.busy))]))
            }
            return .success(Transition(state: .capturing(context), effects: [.startCapture(id), .probeFocus(id)]))
        }

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
                return finish(context, nil, .discarded(reason))
            }
            return move(.transcribing(context), [.transcribe(id)])

        case (.transcribing(var context), .transcribed(_, let transcript, let ms)) where context.capture != nil:
            context.transcribeMs = ms
            if transcript.isBlank {
                return finish(context, transcript, .discarded(.emptyTranscript))
            }
            // Where the text goes, and whether it is a secret the log and the clipboard must not show, both come from
            // the focus. The probe always answers, within its AX timeouts, so a slow one is waited for.
            guard let focus = context.focus else { return move(.resolving(context, transcript)) }
            return move(.resolving(context, transcript), [.resolve(id, transcript, focus)])

        case (.resolving(var context, let transcript), .focusCaptured(_, let focus)) where context.focus == nil:
            context.focus = focus
            return move(.resolving(context, transcript), [.resolve(id, transcript, focus)])

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
                    [.insert(id, transcript.raw, plan, context.focus, clipboardFallback: fallback)])
            case .copy(let reason):
                return move(.copying(context, transcript, reason), [copy(context, transcript)])
            case .discard(let reason):
                return finish(context, transcript, .discarded(reason))
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

        // The engine may still be running (cap reached, converter error): release the microphone.
        case (.capturing(let context), .failed(_, let failure)):
            return finish(context, nil, .failed(failure), cleanup: [.cancelCapture(id)])

        case (.transcribing(let context), .failed(_, let failure))
        where context.capture == nil || !failure.isCaptureFailure:
            return finish(context, nil, .failed(failure))

        case (.acting(let context, let transcript, _), .failed(_, let failure)),
            (.copying(let context, let transcript, _), .failed(_, let failure)):
            return finish(context, transcript, .failed(failure))

        case (.capturing(let context), .cancel):
            return finish(context, nil, .discarded(.cancelled), cleanup: [.cancelCapture(id)])

        case (.transcribing(let context), .cancel):
            let cleanup: PipelineEffect = context.capture == nil ? .cancelCapture(id) : .cancelTranscription(id)
            return finish(context, nil, .discarded(.cancelled), cleanup: [cleanup])

        case (.resolving(let context, let transcript), .cancel):
            return finish(context, transcript, .discarded(.cancelled))

        case (.confirming(let context, let transcript, _, let stage), .cancel):
            let cleanup: [PipelineEffect] = stage == .awaitingAnswer ? [.dismissConfirmation(id)] : []
            return finish(context, transcript, .discarded(.cancelled), cleanup: cleanup)

        default:
            return reject(state, event)
        }
    }

    private func copy(_ context: UtteranceContext, _ transcript: Transcript) -> PipelineEffect {
        .copyToClipboard(context.id, transcript.raw, concealed: context.focus?.isSecureInput ?? false)
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
