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
        nulls: ["error"]),
    .init(
        name: "text inserted",
        record: UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 420), transcript: Transcript(raw: "hi", tier: .medium),
            outcome: .textInserted),
        nulls: ["normalized_text", "action_type", "exit_code", "error"]),
    .init(
        name: "a transcript no engine stamped",
        record: UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 420), transcript: F.transcript, outcome: .textInserted),
        nulls: ["normalized_text", "action_type", "exit_code", "error", "model_tier"]),
    .init(
        name: "a blank transcript keeps its tier",
        record: UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 300), transcript: Transcript(raw: "", tier: .large),
            outcome: .discarded(.emptyTranscript)),
        nulls: ["normalized_text", "action_type", "exit_code"]),
    .init(
        name: "failed action keeps action_type and exit_code",
        record: UtteranceRecord(
            context: F.context(capture: F.speech, transcribeMs: 420, action: .openApp),
            transcript: Transcript(raw: "start the vpn", tier: .small), outcome: .failed(.actionExit(2))),
        nulls: ["normalized_text"]),
    .init(
        name: "busy press",
        record: UtteranceRecord(
            context: UtteranceContext(id: F.other, pressedAt: F.pressedAt), transcript: nil,
            outcome: .discarded(.busy)),
        nulls: [
            "duration_ms", "transcribe_ms", "raw_text", "normalized_text", "action_type", "exit_code", "model_tier",
        ]),
    .init(
        name: "model missing",
        record: UtteranceRecord(
            context: F.context(capture: F.speech), transcript: nil, outcome: .failed(.modelMissing(.small))),
        nulls: ["transcribe_ms", "raw_text", "normalized_text", "action_type", "exit_code", "model_tier"]),
    .init(
        name: "a decode that failed",
        record: UtteranceRecord(
            context: F.context(capture: F.speech), transcript: nil, outcome: .failed(.transcription(code: -6))),
        nulls: ["transcribe_ms", "raw_text", "normalized_text", "action_type", "exit_code", "model_tier"]),
    .init(
        name: "secure input hides the text",
        record: UtteranceRecord(
            context: F.context(
                focus: FocusSnapshot(app: F.mail, isSecureInput: true), capture: F.speech, transcribeMs: 400),
            transcript: Transcript(raw: "hunter2", normalized: "hunter2", tier: .small),
            outcome: .textClipboard(.chosen)),
        nulls: ["raw_text", "normalized_text", "action_type", "exit_code", "error"]),
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
                + #""model_tier":"small"}"#)
    }

    @Test(arguments: outcomeCases)
    func exactlyElevenKeysInOrderWithNulls(_ outcome: OutcomeCase) throws {
        let line = outcome.record.jsonLine(timeZone: F.paris)
        let object = try decode(line)
        #expect(Set(object.keys) == Set(UtteranceRecord.keys))
        #expect(object.count == 11)
        #expect(UtteranceRecord.keys.last == "model_tier", "appended, so a reader of the first ten is unaffected")

        let offsets = UtteranceRecord.keys.compactMap { line.range(of: "\"\($0)\":")?.lowerBound }
        #expect(offsets.count == 11 && offsets == offsets.sorted(), "keys are written in contract order")

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
