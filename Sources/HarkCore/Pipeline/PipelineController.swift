import Foundation
import os

public struct PipelineSnapshot: Sendable, Equatable {
    public var phase: PipelinePhase
    /// The utterance in flight, if any.
    public var utterance: UtteranceContext?
    /// The most recent log line written.
    public var lastRecord: UtteranceRecord?

    public init(phase: PipelinePhase, utterance: UtteranceContext? = nil, lastRecord: UtteranceRecord? = nil) {
        self.phase = phase
        self.utterance = utterance
        self.lastRecord = lastRecord
    }
}

/// Runs the reducer and executes its effects through the environment's seams.
///
/// Each effect that awaits a seam runs in its own task and reports back with an event, so the actor stays
/// responsive: a second press while transcribing is reduced (and logged as busy) immediately. Results that
/// arrive after their utterance ended are rejected by the reducer.
public actor PipelineController {
    public nonisolated let snapshots: AsyncStream<PipelineSnapshot>

    private let continuation: AsyncStream<PipelineSnapshot>.Continuation
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

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "pipeline")

    public init(environment: PipelineEnvironment, log: UtteranceLog, reducer: PipelineReducer = PipelineReducer()) {
        (snapshots, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
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

    public func triggerDown() {
        guard !closed else { return }
        lastID += 1
        send(.triggerDown(UtteranceID(lastID), at: environment.clock.now()))
    }

    public func triggerUp() {
        send(.triggerUp(at: environment.clock.now()))
    }

    public func cancel() {
        send(.cancel)
    }

    public var phase: PipelinePhase { state.phase }

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
            continuation.yield(PipelineSnapshot(phase: state.phase, utterance: state.context, lastRecord: lastRecord))
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
                let copied = await env.pasteboard.writeText(text, concealed: concealed)
                send(copied ? .copied(id) : .failed(id, .pasteboardWrite))
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
