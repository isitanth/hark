import Foundation
import HarkCore
import Testing

struct LegalTransition: Sendable, CustomTestStringConvertible {
    let name: String
    let state: PipelineState
    let event: PipelineEvent
    let phase: PipelinePhase
    let effects: [String]

    var testDescription: String { name }
}

struct IllegalTransition: Sendable, CustomTestStringConvertible {
    let name: String
    let state: PipelineState
    let event: PipelineEvent

    var testDescription: String { name }
}

private typealias F = Fixture

private let at = Fixture.pressedAt

let legalTransitions: [LegalTransition] = [
    .init(
        name: "idle, press: capture and probe focus together", state: .idle, event: .triggerDown(F.id, at: at),
        phase: .capturing, effects: ["startCapture", "probeFocus"]),
    .init(
        name: "capturing, focus arrives", state: F.capturing, event: .focusCaptured(F.id, F.focus),
        phase: .capturing, effects: []),
    .init(
        name: "capturing, release", state: F.capturingFocused, event: .triggerUp(at: at),
        phase: .transcribing, effects: ["stopCapture"]),
    .init(
        name: "capturing, second press is busy", state: F.capturingFocused, event: .triggerDown(F.other, at: at),
        phase: .capturing, effects: ["log:discarded:busy"]),
    .init(
        name: "capturing, length limit reached: the capture stops, the utterance goes on", state: F.capturingFocused,
        event: .captureLimitReached(F.id), phase: .transcribing, effects: ["stopCapture"]),
    .init(
        name: "transcribing, a capture cut at the limit is transcribed", state: F.transcribing,
        event: .captured(F.id, F.maxed), phase: .transcribing, effects: ["transcribe"]),
    .init(
        name: "capturing, cancel", state: F.capturingFocused, event: .cancel,
        phase: .idle, effects: ["cancelCapture", "log:discarded:cancelled"]),
    .init(
        name: "capturing, mic denied", state: F.capturing, event: .failed(F.id, .micPermissionDenied),
        phase: .idle, effects: ["cancelCapture", "log:failed:mic_permission_denied"]),
    .init(
        name: "capturing, no input device", state: F.capturing, event: .failed(F.id, .noInputDevice),
        phase: .idle, effects: ["cancelCapture", "log:failed:no_input_device"]),
    .init(
        name: "capturing, engine start fails", state: F.capturing, event: .failed(F.id, .audioEngine(code: -10868)),
        phase: .idle, effects: ["cancelCapture", "log:failed:audio_engine:-10868"]),
    .init(
        name: "transcribing, late focus", state: F.transcribingUnfocused, event: .focusCaptured(F.id, F.focus),
        phase: .transcribing, effects: []),
    .init(
        name: "transcribing, second press is busy", state: F.transcribingCaptured,
        event: .triggerDown(F.other, at: at), phase: .transcribing, effects: ["log:discarded:busy"]),
    .init(
        name: "transcribing, speech captured", state: F.transcribing, event: .captured(F.id, F.speech),
        phase: .transcribing, effects: ["transcribe"]),
    .init(
        name: "transcribing, too short", state: F.transcribing, event: .captured(F.id, F.short),
        phase: .idle, effects: ["log:discarded:too_short"]),
    .init(
        name: "transcribing, silence", state: F.transcribing, event: .captured(F.id, F.silent),
        phase: .idle, effects: ["log:discarded:no_speech"]),
    .init(
        name: "transcribing, device lost while stopping", state: F.transcribing,
        event: .failed(F.id, .deviceChanged), phase: .idle, effects: ["log:failed:device_changed"]),
    .init(
        name: "transcribing, text", state: F.transcribingCaptured,
        event: .transcribed(F.id, F.transcript, ms: 420), phase: .resolving, effects: ["resolve"]),
    .init(
        name: "transcribing, blank text", state: F.transcribingCaptured,
        event: .transcribed(F.id, Transcript(raw: " \n"), ms: 380), phase: .idle,
        effects: ["log:discarded:empty_transcript"]),
    .init(
        name: "transcribing, model missing", state: F.transcribingCaptured,
        event: .failed(F.id, .modelMissing(.small)), phase: .idle, effects: ["log:failed:model_missing:small"]),
    .init(
        name: "transcribing, model load fails", state: F.transcribingCaptured, event: .failed(F.id, .modelLoad),
        phase: .idle, effects: ["log:failed:model_load"]),
    .init(
        name: "transcribing, whisper error", state: F.transcribingCaptured,
        event: .failed(F.id, .transcription(code: 3)), phase: .idle, effects: ["log:failed:transcription:3"]),
    .init(
        name: "transcribing, cancel while stopping capture", state: F.transcribing, event: .cancel,
        phase: .idle, effects: ["cancelCapture", "log:discarded:cancelled"]),
    .init(
        name: "transcribing, cancel while decoding", state: F.transcribingCaptured, event: .cancel,
        phase: .idle, effects: ["cancelTranscription", "log:discarded:cancelled"]),
    .init(
        name: "resolving, command", state: F.resolving,
        event: .resolved(F.id, normalized: "open finder", .command(F.finder)), phase: .acting,
        effects: ["runAction"]),
    .init(
        name: "resolving, command that needs confirmation", state: F.resolving,
        event: .resolved(F.id, normalized: "ouvre le terminal", .command(F.guarded)), phase: .confirming,
        effects: ["requestConfirmation"]),
    .init(
        name: "resolving, insert", state: F.resolving,
        event: .resolved(F.id, normalized: "open finder", .insert(.axInsert)), phase: .inserting,
        effects: ["insert"]),
    .init(
        name: "resolving, copy", state: F.resolving, event: .resolved(F.id, normalized: nil, .copy(.chosen)),
        phase: .copying, effects: ["copyToClipboard"]),
    .init(
        name: "resolving, clipboard fallback off", state: F.resolving,
        event: .resolved(F.id, normalized: "open finder", .discard(.clipboardFallbackDisabled)), phase: .idle,
        effects: ["log:discarded:clipboard_fallback_disabled"]),
    .init(
        name: "resolving, cancel", state: F.resolving, event: .cancel,
        phase: .idle, effects: ["log:discarded:cancelled"]),
    .init(
        name: "confirming, accepted: restore focus first", state: F.awaitingAnswer, event: .confirmed(F.id, true),
        phase: .confirming, effects: ["restoreFocus"]),
    .init(
        name: "confirming, declined", state: F.awaitingAnswer, event: .confirmed(F.id, false),
        phase: .idle, effects: ["log:discarded:declined"]),
    .init(
        name: "confirming, cancel closes the prompt", state: F.awaitingAnswer, event: .cancel,
        phase: .idle, effects: ["dismissConfirmation", "log:discarded:cancelled"]),
    .init(
        name: "confirming, focus restored", state: F.restoringFocus, event: .focusRestored(F.id, true),
        phase: .acting, effects: ["runAction"]),
    .init(
        name: "confirming, focus not restored", state: F.restoringFocus, event: .focusRestored(F.id, false),
        phase: .idle, effects: ["log:failed:focus_not_restored"]),
    .init(
        name: "acting, exit 0", state: F.acting, event: .actionFinished(F.id, exit: 0),
        phase: .idle, effects: ["log:command"]),
    .init(
        name: "acting, exit 2", state: F.acting, event: .actionFinished(F.id, exit: 2),
        phase: .idle, effects: ["log:failed:action_exit"]),
    .init(
        name: "acting, launch fails", state: F.acting, event: .failed(F.id, .actionLaunch),
        phase: .idle, effects: ["log:failed:action_launch"]),
    .init(
        name: "acting, the app is not there", state: F.acting, event: .failed(F.id, .appNotFound("Frigo")),
        phase: .idle, effects: ["log:failed:app_not_found:Frigo"]),
    .init(
        name: "acting, the app stayed behind", state: F.acting, event: .failed(F.id, .appNotActivated("Finder")),
        phase: .idle, effects: ["log:failed:app_not_activated:Finder"]),
    .init(
        name: "acting, the app quit at once", state: F.acting, event: .failed(F.id, .appExited("Finder")),
        phase: .idle, effects: ["log:failed:app_exited:Finder"]),
    .init(
        name: "transcribing, the engine has shut down for quit", state: F.transcribingCaptured,
        event: .failed(F.id, .quitting), phase: .idle, effects: ["log:failed:quitting"]),
    .init(
        name: "acting, timeout", state: F.acting, event: .failed(F.id, .actionTimeout),
        phase: .idle, effects: ["log:failed:action_timeout"]),
    .init(
        name: "acting, automation denied", state: F.acting,
        event: .failed(F.id, .automationDenied(bundleID: "com.apple.finder")), phase: .idle,
        effects: ["log:failed:automation_denied:com.apple.finder"]),
    .init(
        name: "inserting, done", state: F.inserting, event: .inserted(F.id),
        phase: .idle, effects: ["log:text_inserted"]),
    .init(
        name: "inserting, done after a capture cut at the limit: the line says so",
        state: .inserting(F.context(capture: F.maxed, transcribeMs: 2_400), F.transcript, .axInsert),
        event: .inserted(F.id), phase: .idle, effects: ["log:text_inserted:max_duration"]),
    .init(
        name: "inserting, failure falls back to the clipboard", state: F.inserting,
        event: .failed(F.id, .insertionFailed), phase: .copying, effects: ["copyToClipboard"]),
    .init(
        name: "inserting, focus moved to another app: the clipboard keeps the text", state: F.inserting,
        event: .failed(F.id, .focusChanged), phase: .copying, effects: ["copyToClipboard"]),
    .init(
        name: "inserting, the paste could not write the pasteboard: the clipboard is tried", state: F.inserting,
        event: .failed(F.id, .pasteboardWrite), phase: .copying, effects: ["copyToClipboard"]),
    .init(
        name: "inserting, the AX insertion timed out: the clipboard, not a paste", state: F.inserting,
        event: .failed(F.id, .insertionTimedOut), phase: .copying, effects: ["copyToClipboard"]),
    .init(
        name: "inserting, nothing read the paste: the clipboard keeps the text", state: F.inserting,
        event: .failed(F.id, .pasteNotConsumed), phase: .copying, effects: ["copyToClipboard"]),
    .init(
        name: "copying, done after an insertion that timed out",
        state: .copying(
            F.context(capture: F.speech, transcribeMs: 420), F.transcript, .fallback(.insertionTimedOut)),
        event: .copied(F.id), phase: .idle, effects: ["log:text_clipboard:insertion_timeout"]),
    .init(
        name: "copying, done after a paste nobody read",
        state: .copying(
            F.context(capture: F.speech, transcribeMs: 420), F.transcript, .fallback(.pasteNotConsumed)),
        event: .copied(F.id), phase: .idle, effects: ["log:text_clipboard:paste_not_consumed"]),
    .init(
        name: "copying, done after the focus moved",
        state: .copying(F.context(capture: F.speech, transcribeMs: 420), F.transcript, .fallback(.focusChanged)),
        event: .copied(F.id), phase: .idle, effects: ["log:text_clipboard:focus_changed"]),
    .init(
        name: "transcribing, text before the focus probe answered: wait for it",
        state: .transcribing(F.context(focus: nil, capture: F.speech)),
        event: .transcribed(F.id, F.transcript, ms: 300),
        phase: .resolving, effects: []),
    .init(
        name: "resolving, the late focus arrives: now resolve",
        state: .resolving(F.context(focus: nil, capture: F.speech, transcribeMs: 300), F.transcript),
        event: .focusCaptured(F.id, F.focus), phase: .resolving, effects: ["resolve"]),
    .init(
        name: "resolving, text for a paste", state: F.resolving,
        event: .resolved(F.id, normalized: "open finder", .insert(.paste)), phase: .inserting, effects: ["insert"]),
    .init(
        name: "inserting, failed with the fallback off", state: F.insertingWithoutFallback,
        event: .failed(F.id, .focusChanged), phase: .idle,
        effects: ["log:discarded:clipboard_fallback_disabled"]),
    .init(
        name: "copying, done", state: F.copying, event: .copied(F.id),
        phase: .idle, effects: ["log:text_clipboard"]),
    .init(
        name: "copying, done when nothing took text",
        state: .copying(F.context(capture: F.speech, transcribeMs: 420), F.transcript, .noTextField),
        event: .copied(F.id), phase: .idle, effects: ["log:text_clipboard:no_text_field"]),
    .init(
        name: "copying, done from a password field",
        state: .copying(F.context(capture: F.speech, transcribeMs: 420), F.transcript, .secureField),
        event: .copied(F.id), phase: .idle, effects: ["log:text_clipboard:secure_field"]),
    .init(
        name: "copying, done after an insertion failure", state: F.copyingAfterInsertFailed, event: .copied(F.id),
        phase: .idle, effects: ["log:text_clipboard:insertion_failed"]),
    .init(
        name: "copying, pasteboard write fails", state: F.copying, event: .failed(F.id, .pasteboardWrite),
        phase: .idle, effects: ["log:failed:pasteboard_write"]),
]

let illegalTransitions: [IllegalTransition] = [
    .init(name: "idle, release", state: .idle, event: .triggerUp(at: at)),
    .init(name: "idle, cancel", state: .idle, event: .cancel),
    .init(name: "idle, late capture", state: .idle, event: .captured(F.id, F.speech)),
    .init(name: "idle, late failure", state: .idle, event: .failed(F.id, .modelLoad)),
    .init(name: "idle, late focus", state: .idle, event: .focusCaptured(F.id, F.focus)),
    .init(name: "capturing, event for another utterance", state: F.capturing, event: .focusCaptured(F.other, F.focus)),
    .init(name: "capturing, second focus", state: F.capturingFocused, event: .focusCaptured(F.id, F.focus)),
    .init(name: "capturing, capture ends below the cap", state: F.capturingFocused, event: .captured(F.id, F.speech)),
    .init(name: "capturing, transcript", state: F.capturingFocused, event: .transcribed(F.id, F.transcript, ms: 1)),
    .init(
        name: "capturing, a full capture's summary before the stop", state: F.capturingFocused,
        event: .captured(F.id, F.maxed)),
    .init(name: "transcribing, second release", state: F.transcribing, event: .triggerUp(at: at)),
    .init(
        name: "transcribing, the limit lands after the release: only the stop brings the audio",
        state: F.transcribing, event: .captureLimitReached(F.id)),
    .init(
        name: "transcribing, the limit after the audio", state: F.transcribingCaptured,
        event: .captureLimitReached(F.id)),
    .init(name: "transcribing, second capture", state: F.transcribingCaptured, event: .captured(F.id, F.speech)),
    .init(
        name: "transcribing, device lost after the audio is in", state: F.transcribingCaptured,
        event: .failed(F.id, .deviceChanged)),
    .init(
        name: "transcribing, transcript before audio", state: F.transcribing,
        event: .transcribed(F.id, F.transcript, ms: 1)),
    .init(name: "resolving, failure", state: F.resolving, event: .failed(F.id, .modelLoad)),
    .init(name: "resolving, second transcript", state: F.resolving, event: .transcribed(F.id, F.transcript, ms: 1)),
    .init(name: "confirming, focus before the answer", state: F.awaitingAnswer, event: .focusRestored(F.id, true)),
    .init(name: "confirming, second answer", state: F.restoringFocus, event: .confirmed(F.id, true)),
    .init(name: "acting, cancel is too late", state: F.acting, event: .cancel),
    .init(name: "acting, result for another utterance", state: F.acting, event: .actionFinished(F.other, exit: 0)),
    .init(name: "acting, inserted", state: F.acting, event: .inserted(F.id)),
    .init(name: "resolving, a second focus", state: F.resolving, event: .focusCaptured(F.id, F.focus)),
    .init(name: "inserting, cancel is too late", state: F.inserting, event: .cancel),
    .init(name: "inserting, copied", state: F.inserting, event: .copied(F.id)),
    .init(name: "copying, cancel is too late", state: F.copying, event: .cancel),
    .init(name: "copying, inserted", state: F.copying, event: .inserted(F.id)),
]

@Suite struct PipelineReducerTests {
    let reducer = PipelineReducer()

    @Test(arguments: legalTransitions)
    func legal(_ transition: LegalTransition) throws {
        let result = try reducer.reduce(transition.state, transition.event).get()
        #expect(result.state.phase == transition.phase)
        #expect(result.effects.map(\.label) == transition.effects)
    }

    @Test(arguments: illegalTransitions)
    func illegal(_ transition: IllegalTransition) {
        let result = reducer.reduce(transition.state, transition.event)
        #expect(result == .failure(Rejection(phase: transition.state.phase, event: transition.event)))
    }

    @Test func everyFailureAndDiscardReasonIsCovered() {
        let logged = Set(
            (legalTransitions + askTransitions + assistTransitions).flatMap(\.effects).filter { $0.hasPrefix("log:") })
        let failures: [PipelineFailure] = [
            .micPermissionDenied, .noInputDevice, .deviceChanged, .audioEngine(code: -10868), .modelMissing(.small),
            .modelLoad, .transcription(code: 3), .actionLaunch, .actionTimeout, .actionExit(2),
            .automationDenied(bundleID: "com.apple.finder"), .focusNotRestored, .pasteboardWrite, .llmUnreachable,
            .llmUnauthorized, .llmTimeout, .llmError(status: 500), .llmError(status: nil), .llmEmpty,
        ]
        for failure in failures {
            #expect(logged.contains("log:failed:\(failure.code)"), "no reducer case logs \(failure.code)")
        }
        #expect(logged.contains("log:text_clipboard:insertion_failed"))
        #expect(logged.contains("log:text_clipboard:focus_changed"))
        #expect(logged.contains("log:text_clipboard:insertion_timeout"))
        #expect(logged.contains("log:text_clipboard:paste_not_consumed"))
        #expect(logged.contains("log:text_clipboard:selection_changed"))
        // `max_duration` is no longer a discard: since 2026-09-24 the limit ends the capture and the text goes
        // through, with the code on the `text_inserted` or `command` line instead.
        let notYetReduced: Set<DiscardReason> = [.maxDuration]
        for reason in DiscardReason.allCases where !notYetReduced.contains(reason) {
            #expect(logged.contains("log:discarded:\(reason.rawValue)"), "no reducer case logs \(reason.rawValue)")
        }
        #expect(logged.contains("log:text_inserted:max_duration"))
    }

    @Test(arguments: [false, true])
    func aCopyIsConcealedExactlyWhenTheFocusWasSecure(_ secure: Bool) throws {
        let focus = FocusSnapshot(app: F.mail, isSecureInput: secure)
        let resolving = PipelineState.resolving(
            F.context(focus: focus, capture: F.speech, transcribeMs: 420), F.transcript)
        let copy = try reducer.reduce(resolving, .resolved(F.id, normalized: "open finder", .copy(.noTextField))).get()
        #expect(copy.effects == [.copyToClipboard(F.id, "open finder", concealed: secure)])

        let inserting = PipelineState.inserting(
            F.context(focus: focus, capture: F.speech, transcribeMs: 420), F.transcript, .paste)
        let fallback = try reducer.reduce(inserting, .failed(F.id, .insertionFailed)).get()
        #expect(fallback.effects == [.copyToClipboard(F.id, "open finder", concealed: secure)])
    }

    /// The review's P1: text that arrives before the probe must not be resolved, logged or copied as if the field
    /// were not a password field.
    @Test func aPasswordFieldReportedLateStillHidesTheText() throws {
        let secure = FocusSnapshot(app: F.mail, isSecureInput: true)
        let waiting = try reducer.reduce(
            .transcribing(F.context(focus: nil, capture: F.speech)), .transcribed(F.id, F.transcript, ms: 300)
        ).get()
        #expect(waiting.effects.isEmpty)
        let resolving = try reducer.reduce(waiting.state, .focusCaptured(F.id, secure)).get()
        #expect(resolving.effects == [.resolve(F.id, F.transcript, secure)])
        let copying = try reducer.reduce(
            resolving.state, .resolved(F.id, normalized: "open finder", .copy(.secureField))
        )
        .get()
        #expect(copying.effects == [.copyToClipboard(F.id, "open finder", concealed: true)])
        let done = try reducer.reduce(copying.state, .copied(F.id)).get()
        let record = try #require(done.effects.first?.record)
        #expect(record.rawText == nil && record.normalizedText == nil)
    }

    @Test func aCancelWhileWaitingForTheFocusLogsOnce() throws {
        let waiting = PipelineState.resolving(F.context(focus: nil, capture: F.speech, transcribeMs: 300), F.transcript)
        let done = try reducer.reduce(waiting, .cancel).get()
        #expect(done.state == .idle && done.effects.map(\.label) == ["log:discarded:cancelled"])
    }

    /// The flag the resolver read travels on the context, so the insertion that fails knows what the user chose
    /// even though the reducer never sees the preference.
    @Test(arguments: [false, true])
    func theFallbackFlagDecidesWhereAFailedInsertionEnds(_ fallback: Bool) throws {
        let inserting = try reducer.reduce(
            F.resolving, .resolved(F.id, normalized: "open finder", .insert(.paste, fallback: fallback))
        ).get()
        #expect(inserting.state.phase == .inserting)
        let failed = try reducer.reduce(inserting.state, .failed(F.id, .pasteNotConsumed)).get()
        if fallback {
            #expect(failed.state.phase == .copying)
            #expect(failed.effects.map(\.label) == ["copyToClipboard"])
        } else {
            #expect(failed.state == .idle)
            let record = try #require(failed.effects.first?.record)
            #expect(record.resolution == .discarded)
            #expect(record.error == DiscardReason.clipboardFallbackDisabled.rawValue)
            // The text is dropped, not hidden: the log still says what was heard.
            #expect(record.rawText == "open finder")
        }
    }

    /// A successful insertion ends the same way whatever the fallback says.
    @Test func theFallbackFlagChangesNothingWhenTheInsertionWorks() throws {
        let inserting = try reducer.reduce(
            F.resolving, .resolved(F.id, normalized: "open finder", .insert(.axInsert, fallback: false))
        ).get()
        let done = try reducer.reduce(inserting.state, .inserted(F.id)).get()
        #expect(done.effects.map(\.label) == ["log:text_inserted"])
    }

    @Test func theInsertEffectCarriesTheRawTextThePlanAndTheFocus() throws {
        let result = try reducer.reduce(F.resolving, .resolved(F.id, normalized: "open finder", .insert(.axInsert)))
            .get()
        #expect(result.effects == [.insert(F.id, "open finder", .axInsert, F.focus, clipboardFallback: true)])
    }

    @Test func resolvedTextIsCarriedIntoTheRecord() throws {
        let acting = try reducer.reduce(
            F.resolving, .resolved(F.id, normalized: "open finder", .command(F.finder))
        ).get().state
        let done = try reducer.reduce(acting, .actionFinished(F.id, exit: 0)).get()
        let record = try #require(done.effects.first?.record)
        #expect(record.rawText == "open finder")
        #expect(record.normalizedText == "open finder")
        #expect(record.actionType == .command(.openApp))
        #expect(record.exitCode == 0)
        #expect(record.transcribeMs == 420)
        #expect(record.targetApp == "com.apple.mail")
    }
}
