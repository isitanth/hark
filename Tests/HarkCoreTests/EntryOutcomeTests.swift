import Foundation
import HarkCore
import Testing

private typealias F = Fixture

struct OutcomeReadCase: Sendable, CustomTestStringConvertible {
    let name: String
    let resolution: Resolution
    let error: String?
    let rawText: String?
    let tier: String?
    let outcome: EntryOutcome

    init(
        _ name: String, _ resolution: Resolution, error: String? = nil, rawText: String? = "hi",
        tier: String? = "small", _ outcome: EntryOutcome
    ) {
        self.name = name
        self.resolution = resolution
        self.error = error
        self.rawText = rawText
        self.tier = tier
        self.outcome = outcome
    }

    var testDescription: String { name }

    var entry: LogEntry {
        LogEntry(
            id: "x", timestamp: F.pressedAt, rawText: rawText, resolution: resolution, targetApp: "com.apple.mail",
            actionType: resolution == .command ? "open_app" : nil, error: error, modelTier: tier)
    }
}

let outcomeReadCases: [OutcomeReadCase] = [
    .init("a command", .command, .command(action: "open_app")),
    .init("inserted", .textInserted, .inserted(app: "com.apple.mail")),
    .init("a command cut at the limit", .command, error: "max_duration", .command(action: "open_app", cut: true)),
    .init(
        "inserted, cut at the limit", .textInserted, error: "max_duration", .inserted(app: "com.apple.mail", cut: true)),
    .init("copied as asked", .textClipboard, .copied(.chosen)),
    .init("copied because no field had focus", .textClipboard, error: "no_text_field", .copied(.noTextField)),
    .init("a line from before insertion existed", .textClipboard, tier: nil, .copied(.chosen)),
    // M4 and M5 wrote no reason for a copy the resolver made, so their caught copies read as chosen.
    .init("a caught copy from before M6", .textClipboard, .copied(.chosen)),
    .init("a password field", .textClipboard, error: "secure_field", rawText: nil, .copied(.secureField)),
    .init("a password field in clipboard-only mode", .textClipboard, rawText: nil, .copied(.secureField)),
    .init("focus changed", .textClipboard, error: "focus_changed", .copied(.focusChanged)),
    .init("insertion failed", .textClipboard, error: "insertion_failed", .copied(.insertionFailed)),
    .init("insertion timed out", .textClipboard, error: "insertion_timeout", .copied(.insertionTimedOut)),
    .init("paste not read", .textClipboard, error: "paste_not_consumed", .copied(.pasteNotConsumed)),
    .init("an unknown fallback", .textClipboard, error: "teleport_failed", .copied(.other("teleport_failed"))),
    .init("too short", .discarded, error: "too_short", .discarded(.tooShort, code: "too_short")),
    .init("an unknown discard", .discarded, error: "bored", .discarded(nil, code: "bored")),
    .init("model missing", .failed, error: "model_missing:small", .failed(.modelMissing)),
    .init("microphone denied", .failed, error: "mic_permission_denied", .failed(.microphoneDenied)),
    .init("audio engine", .failed, error: "audio_engine:-10868", .failed(.audioEngine(code: -10868))),
    .init("transcription", .failed, error: "transcription:3", .failed(.transcription(code: 3))),
    .init("transcription without a number", .failed, error: "transcription:x", .failed(.transcription(code: nil))),
    .init("pasteboard write", .failed, error: "pasteboard_write", .failed(.pasteboardWrite)),
    .init("app not found", .failed, error: "app_not_found:Frigo", .failed(.appNotFound(name: "Frigo"))),
    .init("app not found, no name", .failed, error: "app_not_found", .failed(.appNotFound(name: nil))),
    .init("app would not open", .failed, error: "action_launch", .failed(.actionLaunch)),
    .init("app left behind", .failed, error: "app_not_activated:Finder", .failed(.appNotActivated(name: "Finder"))),
    .init("app quit at once", .failed, error: "app_exited:Finder", .failed(.appExited(name: "Finder"))),
    .init("app quit at once, no name", .failed, error: "app_exited", .failed(.appExited(name: nil))),
    .init("quitting", .failed, error: "quitting", .failed(.quitting)),
    .init("automation denied", .failed, error: "automation_denied:com.apple.finder", .failed(.automationDenied)),
    .init(
        "the selection changed before Replace", .textClipboard, error: "selection_changed",
        .copied(.selectionChanged)),
    .init(
        "an empty selection", .discarded, error: "empty_selection", .discarded(.emptySelection, code: "empty_selection")
    ),
    .init("model server not running", .failed, error: "llm_unreachable", .failed(.llmUnreachable)),
    .init("model server refused the key", .failed, error: "llm_unauthorized", .failed(.llmUnauthorized)),
    .init("model server silent", .failed, error: "llm_timeout", .failed(.llmTimeout)),
    .init("model server status", .failed, error: "llm_error:500", .failed(.llmError(status: 500))),
    .init("model server error in the stream", .failed, error: "llm_error", .failed(.llmError(status: nil))),
    .init("model answered nothing", .failed, error: "llm_empty", .failed(.llmEmpty)),
    .init("an unknown failure", .failed, error: "cosmic_ray", .failed(.other("cosmic_ray"))),
    .init("a failure with no code", .failed, .failed(.other(nil))),
]

@Suite struct EntryOutcomeTests {
    @Test(arguments: outcomeReadCases)
    func readsTheLogLine(_ scenario: OutcomeReadCase) {
        #expect(EntryOutcome(scenario.entry) == scenario.outcome)
    }

    /// What the pipeline writes is what the panel reads back: every reason survives the log line.
    @Test(
        arguments: zip(
            [
                ClipboardReason.chosen, .noTextField, .secureField, .fallback(.focusChanged),
                .fallback(.insertionFailed), .fallback(.insertionTimedOut), .fallback(.pasteNotConsumed),
            ],
            [
                EntryOutcome.CopyReason.chosen, .noTextField, .secureField, .focusChanged, .insertionFailed,
                .insertionTimedOut, .pasteNotConsumed,
            ]))
    func everyReasonReadsBackFromTheLine(_ reason: ClipboardReason, _ expected: EntryOutcome.CopyReason) {
        let focus = FocusSnapshot(app: F.mail, isSecureInput: reason == .secureField)
        let record = UtteranceRecord(
            context: F.context(focus: focus, capture: F.speech, transcribeMs: 420), transcript: F.transcript,
            outcome: .textClipboard(reason))
        #expect(record.error == reason.code)
        #expect(EntryOutcome(LogEntry(record: record)) == .copied(expected))
    }

    /// Every failure an insertion can raise reads as a fallback, and the copies that were decided do not.
    @Test func onlyAFailedInsertionIsAFallback() {
        let fallbacks: [PipelineFailure] = [
            .focusChanged, .insertionFailed, .insertionTimedOut, .pasteNotConsumed, .selectionChanged,
        ]
        for failure in fallbacks {
            let entry = LogEntry(
                id: "x", timestamp: F.pressedAt, rawText: "hi", resolution: .textClipboard, error: failure.code)
            let outcome = EntryOutcome(entry)
            #expect(outcome.isFallback, "\(failure.code)")
            #expect(outcome != .copied(.other(failure.code)), "\(failure.code) has words")
        }
        for reason in [EntryOutcome.CopyReason.chosen, .noTextField, .secureField] {
            #expect(!EntryOutcome.copied(reason).isFallback)
        }
        #expect(!EntryOutcome.inserted(app: nil).isFallback)
    }

    /// Only a command or an insertion whose line says `max_duration` reads as cut.
    @Test func onlyAMaxDurationLineIsCut() {
        let cut = LogEntry(
            id: "x", timestamp: F.pressedAt, rawText: "hi", resolution: .textInserted, error: "max_duration")
        #expect(EntryOutcome(cut).isCut)
        let whole = LogEntry(id: "x", timestamp: F.pressedAt, rawText: "hi", resolution: .textInserted)
        #expect(!EntryOutcome(whole).isCut)
        #expect(!EntryOutcome.copied(.chosen).isCut)
    }

    /// The review's P3: a command said with a password field focused showed "Nothing yet" under LAST.
    @Test(
        arguments: [
            (Resolution.command, "small", nil, true), (.failed, "small", "app_not_found:Frigo", true),
            (.textClipboard, "small", "secure_field", true), (.textClipboard, nil, nil, true),
            (.discarded, nil, "too_short", false), (.failed, nil, "model_missing:small", false),
            (.command, nil, nil, false),
        ] as [(Resolution, String?, String?, Bool)])
    func aTranscriptTheLineWithheldIsSaidToBeHidden(
        _ resolution: Resolution, _ tier: String?, _ error: String?, _ hidden: Bool
    ) {
        let entry = LogEntry(
            id: "x", timestamp: F.pressedAt, rawText: nil, resolution: resolution, error: error, modelTier: tier)
        #expect(entry.hidesTranscript == hidden)
        let spoken = LogEntry(
            id: "y", timestamp: F.pressedAt, rawText: "Ouvre le Finder.", resolution: resolution, modelTier: tier)
        #expect(!spoken.hidesTranscript)
    }
}
