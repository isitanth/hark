import Foundation
import HarkCore
import Testing

private typealias F = Fixture

struct OutcomeCase: Sendable, CustomTestStringConvertible {
    let name: String
    let record: UtteranceRecord
    /// Keys whose value must be JSON null.
    let nulls: Set<String>

    var testDescription: String { name }
}

let outcomeCases: [OutcomeCase] = [
    .init(
        name: "command",
        record: UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 420, action: .openApp),
            transcript: Transcript(raw: "Open Finder.", normalized: "open finder", tier: .small), outcome: .command),
        nulls: ["error", "llm_model", "llm_ms"]),
    .init(
        name: "text inserted",
        record: UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 420), transcript: Transcript(raw: "hi", tier: .medium),
            outcome: .textInserted),
        nulls: ["normalized_text", "action_type", "exit_code", "error", "llm_model", "llm_ms"]),
    .init(
        name: "a transcript no engine stamped",
        record: UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 420), transcript: F.transcript, outcome: .textInserted),
        nulls: ["normalized_text", "action_type", "exit_code", "error", "model_tier", "llm_model", "llm_ms"]),
    .init(
        name: "a blank transcript keeps its tier",
        record: UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 300), transcript: Transcript(raw: "", tier: .large),
            outcome: .discarded(.emptyTranscript)),
        nulls: ["normalized_text", "action_type", "exit_code", "llm_model", "llm_ms"]),
    .init(
        name: "failed action keeps action_type and exit_code",
        record: UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 420, action: .openApp),
            transcript: Transcript(raw: "start the vpn", tier: .small), outcome: .failed(.actionExit(2))),
        nulls: ["normalized_text", "llm_model", "llm_ms"]),
    .init(
        name: "busy press",
        record: UtteranceRecord(
            context: UtteranceContext(id: F.other, pressedAt: F.pressedAt), transcript: nil,
            outcome: .discarded(.busy)),
        nulls: [
            "duration_ms", "transcribe_ms", "raw_text", "normalized_text", "action_type", "exit_code", "model_tier",
            "llm_model", "llm_ms",
        ]),
    .init(
        name: "model missing",
        record: UtteranceRecord(
            context: F.context(capture: F.speech), transcript: nil, outcome: .failed(.modelMissing(.small))),
        nulls: [
            "transcribe_ms", "raw_text", "normalized_text", "action_type", "exit_code", "model_tier", "llm_model",
            "llm_ms",
        ]),
    .init(
        name: "a decode that failed",
        record: UtteranceRecord(
            context: F.context(capture: F.speech), transcript: nil, outcome: .failed(.transcription(code: -6))),
        nulls: [
            "transcribe_ms", "raw_text", "normalized_text", "action_type", "exit_code", "model_tier", "llm_model",
            "llm_ms",
        ]),
    .init(
        name: "secure input hides the text",
        record: UtteranceRecord(
            context: F.context(
                focus: FocusSnapshot(app: F.mail, isSecureInput: true), capture: F.speech, transcribeMs: 400),
            transcript: Transcript(raw: "hunter2", normalized: "hunter2", tier: .small),
            outcome: .textClipboard(.chosen)),
        nulls: ["raw_text", "normalized_text", "action_type", "exit_code", "error", "llm_model", "llm_ms"]),
    .init(
        name: "an ask copied",
        record: UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 380, intent: .ask, llmModel: F.bonsai, llmMs: 3_420),
            transcript: Transcript(raw: "Résume ce texte.", tier: .small), outcome: .textClipboard(.chosen)),
        nulls: ["normalized_text", "exit_code", "error"]),
    .init(
        name: "an ask replaced",
        record: UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 380, intent: .ask, llmModel: F.bonsai, llmMs: 2_610),
            transcript: Transcript(raw: "Traduis en anglais.", tier: .small), outcome: .textInserted),
        nulls: ["normalized_text", "exit_code", "error"]),
    .init(
        name: "an ask whose server was down",
        record: UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 380, intent: .ask),
            transcript: Transcript(raw: "Résume ce texte.", tier: .small), outcome: .failed(.llmUnreachable)),
        nulls: ["normalized_text", "exit_code", "llm_model", "llm_ms"]),
    .init(
        name: "an ask on an empty selection",
        record: UtteranceRecord(
            context: UtteranceContext(id: F.id, pressedAt: F.pressedAt, intent: .ask), transcript: nil,
            outcome: .discarded(.emptySelection)),
        nulls: [
            "duration_ms", "transcribe_ms", "raw_text", "normalized_text", "exit_code", "model_tier", "llm_model",
            "llm_ms",
        ]),
]

@Suite struct UtteranceRecordEncodingTests {
    private func decode(_ line: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try #require(object as? [String: Any])
    }

    @Test func goldenLine() {
        let record = UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 420, action: .openApp),
            transcript: Transcript(raw: "Open Finder.", normalized: "open finder", tier: .small), outcome: .command)
        #expect(
            record.jsonLine(timeZone: F.paris)
                == #"{"ts":"2026-09-18T14:03:12.345+02:00","duration_ms":1800,"transcribe_ms":420,"#
                + #""raw_text":"Open Finder.","normalized_text":"open finder","resolution":"command","#
                + #""target_app":"com.apple.mail","action_type":"open_app","exit_code":0,"error":null,"#
                + #""model_tier":"small","llm_model":null,"llm_ms":null}"#)
    }

    @Test func goldenAskLine() {
        let record = UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 380, intent: .ask, llmModel: F.bonsai, llmMs: 3_420),
            transcript: Transcript(raw: "Résume ce texte.", tier: .small), outcome: .textClipboard(.chosen))
        #expect(
            record.jsonLine(timeZone: F.paris)
                == #"{"ts":"2026-09-18T14:03:12.345+02:00","duration_ms":1800,"transcribe_ms":380,"#
                + #""raw_text":"Résume ce texte.","normalized_text":null,"resolution":"text_clipboard","#
                + #""target_app":"com.apple.mail","action_type":"ask","exit_code":null,"error":null,"#
                + #""model_tier":"small","llm_model":"mtplx-bonsai-2-27b-optimized-speed","llm_ms":3420}"#)
    }

    @Test(arguments: outcomeCases)
    func exactlyThirteenKeysInOrderWithNulls(_ outcome: OutcomeCase) throws {
        let line = outcome.record.jsonLine(timeZone: F.paris)
        let object = try decode(line)
        #expect(Set(object.keys) == Set(UtteranceRecord.keys))
        #expect(object.count == 13)
        #expect(
            Array(UtteranceRecord.keys.suffix(3)) == ["model_tier", "llm_model", "llm_ms"],
            "appended, so a reader of the first eleven is unaffected")

        let offsets = UtteranceRecord.keys.compactMap { line.range(of: "\"\($0)\":")?.lowerBound }
        #expect(offsets.count == 13 && offsets == offsets.sorted(), "keys are written in contract order")

        let nulls = Set(object.filter { $0.value is NSNull }.map(\.key))
        #expect(nulls == outcome.nulls)
    }

    @Test func busyPressFields() throws {
        let record = try #require(outcomeCases.first { $0.name == "busy press" }?.record)
        let object = try decode(record.jsonLine(timeZone: F.paris))
        #expect(object["resolution"] as? String == "discarded")
        #expect(object["error"] as? String == "busy")
        #expect(object["target_app"] as? String == "unknown")
    }

    @Test(arguments: ModelTier.allCases)
    func theTierIsWrittenAsItsRawValue(_ tier: ModelTier) throws {
        let record = UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 420), transcript: Transcript(raw: "hi", tier: tier),
            outcome: .textClipboard(.chosen))
        #expect(try decode(record.jsonLine(timeZone: F.paris))["model_tier"] as? String == tier.rawValue)
    }

    @Test func secureInputHidesTheTextButKeepsTheTier() throws {
        let record = try #require(outcomeCases.first { $0.name.hasPrefix("secure input") }?.record)
        #expect(record.rawText == nil && record.modelTier == .small)
    }

    @Test func failedActionFields() throws {
        let record = try #require(outcomeCases.first { $0.name.hasPrefix("failed action") }?.record)
        let object = try decode(record.jsonLine(timeZone: F.paris))
        #expect(object["resolution"] as? String == "failed")
        #expect(object["action_type"] as? String == "open_app")
        #expect(object["exit_code"] as? Int == 2)
        #expect(object["error"] as? String == "action_exit")
    }

    @Test func textIsEscapedAndRoundTrips() throws {
        let text = "say \"hi\" \\ then\nnew line\ttab, é, 😀, \u{1}, \u{2028}"
        let record = UtteranceRecord(
            context: F.context(capture: F.speech), transcript: Transcript(raw: text),
            outcome: .textClipboard(.chosen))
        let line = record.jsonLine(timeZone: F.paris)
        #expect(!line.contains("\n"))
        #expect(try decode(line)["raw_text"] as? String == text)
    }

    @Test(arguments: [
        ("Europe/Paris", "2026-09-18T14:03:12.345+02:00"),
        ("America/New_York", "2026-09-18T08:03:12.345-04:00"),
        ("Asia/Kolkata", "2026-09-18T17:33:12.345+05:30"),
    ])
    func timestampHasMillisecondsAndLocalOffset(_ zone: String, _ expected: String) throws {
        let timeZone = try #require(TimeZone(identifier: zone))
        let record = UtteranceRecord(context: F.context(), transcript: nil, outcome: .discarded(.cancelled))
        #expect(try decode(record.jsonLine(timeZone: timeZone))["ts"] as? String == expected)
    }

    @Test func durationFallsBackToPressLength() {
        let record = UtteranceRecord(context: F.context(), transcript: nil, outcome: .discarded(.cancelled))
        #expect(record.durationMs == 1800)
    }
}

struct CutCase: Sendable, CustomTestStringConvertible {
    let name: String
    let outcome: PipelineOutcome
    let capture: CaptureSummary
    let error: String?

    var testDescription: String { name }
}

/// A capture cut at the length limit: `max_duration` on the lines whose text went through, and nothing else
/// displaced by it.
let cutCases: [CutCase] = [
    .init(name: "text inserted", outcome: .textInserted, capture: F.maxed, error: "max_duration"),
    .init(name: "command", outcome: .command, capture: F.maxed, error: "max_duration"),
    .init(name: "clipboard chosen keeps null", outcome: .textClipboard(.chosen), capture: F.maxed, error: nil),
    .init(
        name: "clipboard reason wins", outcome: .textClipboard(.noTextField), capture: F.maxed,
        error: "no_text_field"),
    .init(name: "discard reason wins", outcome: .discarded(.noSpeech), capture: F.maxed, error: "no_speech"),
    .init(
        name: "failure wins", outcome: .failed(.modelMissing(.small)), capture: F.maxed,
        error: "model_missing:small"),
    .init(name: "a capture under the limit", outcome: .textInserted, capture: F.speech, error: nil),
]

@Suite struct CutCaptureRecordTests {
    @Test(arguments: cutCases)
    func errorNamesTheCut(_ cut: CutCase) {
        let record = UtteranceRecord(
            context: F.context(capture: cut.capture, transcribeMs: 420),
            transcript: Transcript(raw: "hi", tier: .small), outcome: cut.outcome)
        #expect(record.error == cut.error)
        #expect(record.durationMs == cut.capture.durationMs)
    }
}

struct LLMKeysCase: Sendable, CustomTestStringConvertible {
    let name: String
    let context: UtteranceContext
    let outcome: PipelineOutcome
    let actionType: String?
    let llmModel: String?
    let llmMs: Int?

    var testDescription: String { name }
}

/// `llm_model` and `llm_ms` are null on every line with no LLM call, and an ask writes `action_type: ask` whatever
/// became of it.
let llmKeysCases: [LLMKeysCase] = [
    .init(
        name: "dictation", context: F.context(capture: F.speech, transcribeMs: 420), outcome: .textInserted,
        actionType: nil, llmModel: nil, llmMs: nil),
    .init(
        name: "dictation copied", context: F.context(capture: F.speech, transcribeMs: 420),
        outcome: .textClipboard(.noTextField), actionType: nil, llmModel: nil, llmMs: nil),
    .init(
        name: "command", context: F.context(capture: F.speech, transcribeMs: 420, action: .openApp),
        outcome: .command, actionType: "open_app", llmModel: nil, llmMs: nil),
    .init(
        name: "failed command", context: F.context(capture: F.speech, transcribeMs: 420, action: .openApp),
        outcome: .failed(.appNotFound("Frigo")), actionType: "open_app", llmModel: nil, llmMs: nil),
    .init(
        name: "ask copied", context: F.context(capture: F.speech, intent: .ask, llmModel: F.bonsai, llmMs: 3_420),
        outcome: .textClipboard(.chosen), actionType: "ask", llmModel: F.bonsai, llmMs: 3_420),
    .init(
        name: "ask replaced", context: F.context(capture: F.speech, intent: .ask, llmModel: F.bonsai, llmMs: 2_610),
        outcome: .textInserted, actionType: "ask", llmModel: F.bonsai, llmMs: 2_610),
    .init(
        name: "ask with the selection changed",
        context: F.context(capture: F.speech, intent: .ask, llmModel: F.bonsai, llmMs: 2_610),
        outcome: .textClipboard(.fallback(.selectionChanged)), actionType: "ask", llmModel: F.bonsai, llmMs: 2_610),
    .init(
        name: "ask cancelled while streaming",
        context: F.context(capture: F.speech, intent: .ask, llmModel: F.bonsai, llmMs: 900),
        outcome: .discarded(.cancelled), actionType: "ask", llmModel: F.bonsai, llmMs: 900),
    .init(
        name: "ask timed out, no model answered", context: F.context(capture: F.speech, intent: .ask, llmMs: 15_000),
        outcome: .failed(.llmTimeout), actionType: "ask", llmModel: nil, llmMs: 15_000),
    .init(
        name: "ask cancelled before the request", context: F.context(intent: .ask), outcome: .discarded(.cancelled),
        actionType: "ask", llmModel: nil, llmMs: nil),
]

@Suite struct LLMKeysRecordTests {
    @Test(arguments: llmKeysCases)
    func theLLMKeysAndTheActionType(_ scenario: LLMKeysCase) throws {
        let record = UtteranceRecord(
            context: scenario.context, transcript: Transcript(raw: "hi", tier: .small), outcome: scenario.outcome)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(record.jsonLine(timeZone: F.paris).utf8)) as? [String: Any])
        #expect(object.count == 13)
        #expect(object["action_type"] as? String == scenario.actionType)
        #expect(object["llm_model"] as? String == scenario.llmModel)
        #expect(object["llm_ms"] as? Int == scenario.llmMs)
        #expect((object["llm_model"] is NSNull) == (scenario.llmModel == nil))
        #expect((object["llm_ms"] is NSNull) == (scenario.llmMs == nil))
    }

    /// `ask` stays unambiguous: no command action can ever be written as it.
    @Test func noCommandActionIsWrittenAsAsk() {
        #expect(!ActionType.allCases.map(\.rawValue).contains(LoggedAction.askRawValue))
        #expect(LoggedAction.ask.rawValue == "ask")
        for action in ActionType.allCases {
            #expect(LoggedAction.command(action).rawValue == action.rawValue)
        }
    }

    /// An ask never carries a command's action, even if one was set on its context.
    @Test func anAskIsWrittenAsAskEvenWithAnAction() {
        let record = UtteranceRecord(
            context: F.context(capture: F.speech, action: .openApp, intent: .ask), transcript: nil,
            outcome: .failed(.llmEmpty))
        #expect(record.actionType == .ask)
    }
}
