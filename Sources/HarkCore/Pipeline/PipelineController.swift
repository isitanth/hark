import Foundation
import os

public struct PipelineSnapshot: Sendable, Equatable {
    public var phase: PipelinePhase
    /// The utterance in flight, if any.
    public var utterance: UtteranceContext?
    /// The most recent log line written.
    public var lastRecord: UtteranceRecord?
    /// The instruction and the stage while an ask is in `.asking`.
    public var ask: AskProgress?

    public init(
        phase: PipelinePhase, utterance: UtteranceContext? = nil, lastRecord: UtteranceRecord? = nil,
        ask: AskProgress? = nil
    ) {
        self.phase = phase
        self.utterance = utterance
        self.lastRecord = lastRecord
        self.ask = ask
    }
}

/// An ask's answer so far, for the popup: the whole text streamed until now. Each request starts with an empty one, so
/// a Retry clears what the failed call had shown.
public struct AskUpdate: Sendable, Equatable {
    public let id: UtteranceID
    public let text: String

    public init(id: UtteranceID, text: String) {
        self.id = id
        self.text = text
    }
}

/// Runs the reducer and executes its effects through the environment's seams.
///
/// Each effect that awaits a seam runs in its own task and reports back with an event, so the actor stays
/// responsive: a second press while transcribing is reduced (and logged as busy) immediately. Results that
/// arrive after their utterance ended are rejected by the reducer.
public actor PipelineController {
    public nonisolated let snapshots: AsyncStream<PipelineSnapshot>
    /// The streamed answer, apart from the snapshots: the reducer sees only the end of a generation.
    public nonisolated let askUpdates: AsyncStream<AskUpdate>

    private let continuation: AsyncStream<PipelineSnapshot>.Continuation
    private let askContinuation: AsyncStream<AskUpdate>.Continuation
    private let environment: PipelineEnvironment
    private let log: UtteranceLog
    private let reducer: PipelineReducer
    private let stopwatch = ContinuousClock()

    private var state = PipelineState.idle
    private var lastRecord: UtteranceRecord?
    private var lastID: UInt64 = 0
    /// Set by `quit`: a press after it starts nothing.
    private var closed = false
    /// Samples between `AudioInput.stop` and the `.transcribe` effect. Lives only for one `send(.captured)`.
    private var capturedSamples: (id: UtteranceID, samples: [Float])?
    /// The ask's stream being read. Cancelling it closes the request.
    private var generation: Task<Void, Never>?

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "pipeline")

    public init(environment: PipelineEnvironment, log: UtteranceLog, reducer: PipelineReducer = PipelineReducer()) {
        (snapshots, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
        // Each update holds the whole text, so only the newest matters.
        (askUpdates, askContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.environment = environment
        self.log = log
        self.reducer = reducer
        continuation.yield(PipelineSnapshot(phase: .idle))

        let audioEvents = environment.audio.events
        Task { [weak self] in
            for await event in audioEvents {
                await self?.handle(event)
            }
        }
    }

    deinit {
        continuation.finish()
        askContinuation.finish()
    }

    /// Quitting: nothing starts, the utterance in flight is cancelled where it can be, and this returns once the pipeline
    /// is idle, so that utterance's one log line is on disk before the process exits. An insertion, a copy or an action
    /// under way finishes; the caller's deadline bounds the wait.
    public func quit() async {
        closed = true
        if state.phase != .idle { send(.cancel) }
        while state.phase != .idle {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    public func triggerDown(intent: CaptureIntent = .dictate) {
        guard !closed else { return }
        lastID += 1
        send(.triggerDown(UtteranceID(lastID), at: environment.clock.now(), intent: intent))
    }

    public func triggerUp() {
        send(.triggerUp(at: environment.clock.now()))
    }

    public func cancel() {
        send(.cancel)
    }

    /// The Ask panel's Done or Return: a release for `id`, if it is still the utterance in flight. A click that lands
    /// after the ask ended must not end the next one.
    public func finishCapture(_ id: UtteranceID) {
        guard state.context?.id == id else { return }
        triggerUp()
    }

    /// The Ask panel's Cancel or Esc, for `id` only.
    public func cancel(_ id: UtteranceID) {
        guard state.context?.id == id else { return }
        send(.cancel)
    }

    public func retryAsk(_ id: UtteranceID) {
        send(.askRetry(id))
    }

    /// Copy in the Ask panel: `text` is the suggestion as the user left it.
    public func copyAnswer(_ text: String, for id: UtteranceID) {
        send(.askCopy(id, text))
    }

    /// Replace in the Ask panel: `text` goes in place of the caller's selection, once it is checked.
    public func replaceSelection(with text: String, for id: UtteranceID) {
        send(.askReplace(id, text))
    }

    public var phase: PipelinePhase { state.phase }

    /// What the capture under way is for; nil when nothing is being captured. The talk key reads it to end an ask's
    /// capture instead of starting a busy utterance.
    public var capturingIntent: CaptureIntent? {
        guard case .capturing(let context) = state else { return nil }
        return context.intent
    }

    private func handle(_ event: AudioInputEvent) {
        switch event {
        case .reachedMaxDuration(let id, _):
            send(.captureLimitReached(id))
        case .interrupted(let id, let failure):
            send(.failed(id, failure))
        }
    }

    private func send(_ event: PipelineEvent) {
        switch reducer.reduce(state, event) {
        case .failure(let rejection):
            Self.logger.debug("dropped \(String(describing: rejection.event)) in \(rejection.phase.rawValue)")
        case .success(let transition):
            state = transition.state
            for effect in transition.effects {
                perform(effect)
            }
            continuation.yield(
                PipelineSnapshot(phase: state.phase, utterance: state.context, lastRecord: lastRecord, ask: state.ask))
        }
    }

    private func perform(_ effect: PipelineEffect) {
        let env = environment
        switch effect {
        case .writeLog(let record):
            log.append(record)
            lastRecord = record

        case .startCapture(let id):
            Task {
                do throws(PipelineFailure) {
                    try await env.audio.start(id)
                } catch {
                    send(.failed(id, error))
                }
            }

        case .probeFocus(let id):
            Task {
                send(.focusCaptured(id, await env.focus.probe()))
            }

        case .stopCapture(let id):
            Task {
                do throws(PipelineFailure) {
                    let audio = try await env.audio.stop(id)
                    capturedSamples = (id, audio.samples)
                    send(.captured(id, audio.summary))
                    capturedSamples = nil
                } catch {
                    send(.failed(id, error))
                }
            }

        case .cancelCapture(let id):
            Task { await env.audio.cancel(id) }

        case .transcribe(let id):
            guard let captured = capturedSamples, captured.id == id else {
                Self.logger.fault("no captured samples for utterance \(id)")
                Task { send(.failed(id, .transcription(code: -1))) }
                return
            }
            capturedSamples = nil
            let started = stopwatch.now
            Task {
                do throws(PipelineFailure) {
                    let transcript = try await env.engine.transcribe(captured.samples)
                    send(.transcribed(id, transcript, ms: started.duration(to: stopwatch.now).wholeMilliseconds))
                } catch {
                    send(.failed(id, error))
                }
            }

        case .cancelTranscription:
            Task { await env.engine.cancel() }

        case .resolve(let id, let transcript, let focus):
            Task {
                let result = await env.resolver.resolve(transcript, focus: focus)
                send(.resolved(id, normalized: result.normalized, result.decision))
            }

        case .requestConfirmation(let id, let command):
            Task {
                let accepted = await env.confirmation.confirm(command)
                send(.confirmed(id, accepted))
            }

        case .dismissConfirmation:
            Task { await env.confirmation.dismiss() }

        case .restoreFocus(let id, let focus):
            Task {
                guard let app = focus?.app else {
                    send(.focusRestored(id, true))
                    return
                }
                let restored = await env.workspace.activate(app)
                send(.focusRestored(id, restored))
            }

        case .runAction(let id, let command):
            Task {
                do throws(PipelineFailure) {
                    let exit = try await env.actions.run(command)
                    send(.actionFinished(id, exit: exit))
                } catch {
                    send(.failed(id, error))
                }
            }

        case .insert(let id, let text, let plan, let focus, let clipboardFallback):
            Task {
                do throws(PipelineFailure) {
                    try await env.inserter.insert(
                        text, plan: plan, focus: focus, clipboardFallback: clipboardFallback)
                    send(.inserted(id))
                } catch {
                    send(.failed(id, error))
                }
            }

        case .copyToClipboard(let id, let text, let concealed):
            Task {
                await env.inserter.releasePasteboard()
                let copied = await env.pasteboard.writeText(text, concealed: concealed)
                send(copied ? .copied(id) : .failed(id, .pasteboardWrite))
            }

        case .generate(let id, let instruction, let selection):
            generation?.cancel()
            askContinuation.yield(AskUpdate(id: id, text: ""))
            let events = env.asker.generate(instruction: instruction, selection: selection?.text)
            generation = Task {
                var text = ""
                for await event in events {
                    switch event {
                    case .text(let piece):
                        text += piece
                        askContinuation.yield(AskUpdate(id: id, text: text))
                    case .finished(let summary):
                        send(.generated(id, summary))
                    case .failed(let failure, let summary):
                        send(.generationFailed(id, failure, summary))
                    }
                }
            }

        case .cancelGeneration:
            generation?.cancel()
            generation = nil

        case .checkSelection(let id, let selection):
            Task {
                send(.selectionChecked(id, await env.selection.check(selection)))
            }
        }
    }
}

extension Duration {
    fileprivate var wholeMilliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
