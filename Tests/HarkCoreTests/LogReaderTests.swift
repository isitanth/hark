import Foundation
import HarkCore
import Testing

private typealias F = Fixture

@Suite struct LogReaderTests {
    /// Sub-millisecond offsets, because a real key-down time has them and the log does not keep them.
    private static let records: [UtteranceRecord] = [
        UtteranceRecord(
            context: F.context(
                pressedAt: F.pressedAt.addingTimeInterval(0.000_4), capture: F.speech, transcribeMs: 420),
            transcript: Transcript(
                raw: "say \"hi\" \\ then\nnew line\ttab, é, 😀, \u{1}, \u{2028}, \u{2029}", tier: .small),
            outcome: .textClipboard(.fallback(.insertionFailed))),
        UtteranceRecord(
            context: F.context(
                pressedAt: F.pressedAt.addingTimeInterval(4.123_456), capture: F.speech, transcribeMs: 380,
                action: .openApp),
            transcript: Transcript(raw: "Open Finder.", normalized: "open finder", tier: .large), outcome: .command),
        UtteranceRecord(
            context: UtteranceContext(id: F.other, pressedAt: F.pressedAt.addingTimeInterval(7.999_9)),
            transcript: nil, outcome: .discarded(.busy)),
        UtteranceRecord(
            context: F.context(
                pressedAt: F.pressedAt.addingTimeInterval(9.5), capture: F.speech, transcribeMs: 400, action: .openApp),
            transcript: Transcript(raw: "start the vpn"), outcome: .failed(.actionExit(-2))),
        UtteranceRecord(
            context: F.context(
                pressedAt: F.pressedAt.addingTimeInterval(11.000_01),
                focus: FocusSnapshot(app: F.mail, isSecureInput: true), capture: F.speech, transcribeMs: 400),
            transcript: Transcript(raw: "hunter2"), outcome: .textInserted),
        UtteranceRecord(
            context: F.context(
                pressedAt: F.pressedAt.addingTimeInterval(13.25), capture: F.speech, transcribeMs: 380, intent: F.ask,
                llmModel: F.bonsai, llmMs: 3_420),
            transcript: Transcript(raw: "Résume ce texte.", tier: .small), outcome: .textClipboard(.chosen)),
    ]

    private static func record(at date: Date, _ outcome: PipelineOutcome) -> UtteranceRecord {
        UtteranceRecord(
            context: F.context(pressedAt: date, capture: F.speech), transcript: F.transcript, outcome: outcome)
    }

    /// The same entry under another id, so entries compare on their ten fields and the timestamp alone.
    private static func renamed(_ entry: LogEntry, _ id: String = "") -> LogEntry {
        LogEntry(
            id: id, timestamp: entry.timestamp, durationMs: entry.durationMs, transcribeMs: entry.transcribeMs,
            rawText: entry.rawText, normalizedText: entry.normalizedText, resolution: entry.resolution,
            targetApp: entry.targetApp, actionType: entry.actionType, exitCode: entry.exitCode, error: entry.error,
            modelTier: entry.modelTier, llmModel: entry.llmModel, llmMs: entry.llmMs)
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test(arguments: ["Europe/Paris", "Asia/Kolkata", "America/New_York"])
    func whatTheWriterAppendsReadsBackAsTheLiveEntry(_ zone: String) throws {
        let directory = try TemporaryDirectory()
        let timeZone = try #require(TimeZone(identifier: zone))
        let log = UtteranceLog(directory: directory.url, timeZone: timeZone)
        for record in Self.records {
            #expect(log.append(record))
        }

        let page = LogReader(directory: directory.url).read()

        #expect(page.unreadableLines == 0)
        let name = log.fileURL(for: F.pressedAt).lastPathComponent
        #expect(page.entries.map(\.id) == (1...Self.records.count).reversed().map { "\(name):\($0)" })
        let live = Self.records.reversed().map { Self.renamed(LogEntry(record: $0)) }
        #expect(page.entries.map { Self.renamed($0) } == live)
    }

    /// Why `LogEntry(record:)` goes through the written form: the log keeps milliseconds, a key-down time has more,
    /// and `RecentFeed` merges the launch seed with live entries by timestamp.
    @Test func theLiveEntryCarriesTheTimestampTheLogKeeps() throws {
        let directory = try TemporaryDirectory()
        let log = UtteranceLog(directory: directory.url, timeZone: F.paris)
        let record = try #require(Self.records.first)
        log.append(record)

        let read = try #require(LogReader(directory: directory.url).read().entries.first)

        #expect(read.timestamp != record.timestamp, "the premise: the log drops the sub-millisecond part")
        #expect(read.timestamp == LogEntry(record: record).timestamp)
        #expect(abs(read.timestamp.timeIntervalSince(record.timestamp)) < 0.001)
    }

    @Test func newestDayFirstThenNewestLineFirst() throws {
        let directory = try TemporaryDirectory()
        let log = UtteranceLog(directory: directory.url, timeZone: F.paris)
        for offset in [-2.0, -1.0, 1.0, 2.0] {
            log.append(Self.record(at: F.beforeMidnight.addingTimeInterval(offset), .textInserted))
        }

        let reader = LogReader(directory: directory.url)

        #expect(
            reader.read().entries.map(\.id) == [
                "2026-09-19.jsonl:2", "2026-09-19.jsonl:1", "2026-09-18.jsonl:2", "2026-09-18.jsonl:1",
            ])
        #expect(reader.newestFile()?.lastPathComponent == "2026-09-19.jsonl")
        #expect(reader.newestFile() == log.fileURL(for: F.beforeMidnight.addingTimeInterval(1)))
    }

    /// The writer's line and its newline arrive in one write, so a file without a final newline is mid-write.
    @Test(arguments: [
        #"{"ts":"2026-09-18T14:03:"#,
        #"{"ts":"2026-09-18T14:03:30.000+02:00","resolution":"command"}"#,
        #"garbage"#,
    ])
    func aTrailingLineWithoutANewlineIsSkippedAndNotCounted(_ tail: String) throws {
        let directory = try TemporaryDirectory()
        let log = UtteranceLog(directory: directory.url, timeZone: F.paris)
        log.append(Self.record(at: F.pressedAt, .textInserted))
        log.append(Self.record(at: F.pressedAt.addingTimeInterval(1), .command))
        try Self.append(tail, to: log.fileURL(for: F.pressedAt))

        let page = LogReader(directory: directory.url).read()

        #expect(page.entries.map(\.id) == ["2026-09-18.jsonl:2", "2026-09-18.jsonl:1"])
        #expect(page.unreadableLines == 0)
    }

    @Test func completeLinesThatDoNotDecodeAreCounted() throws {
        let directory = try TemporaryDirectory()
        let good = Self.record(at: F.pressedAt, .textInserted).jsonLine(timeZone: F.paris)
        let lines = [
            good,
            "garbage",
            "",
            "[1,2]",
            #"{"ts":"2026-09-18T14:03:12.345+02:00"}"#,
            #"{"resolution":"command"}"#,
            #"{"ts":"yesterday","resolution":"command"}"#,
            #"{"ts":"2026-09-18T14:03:12.345","resolution":"command"}"#,
            #"{"ts":1789732992,"resolution":"command"}"#,
            #"{"ts":"2026-09-18T14:03:12.345+02:00","resolution":"teleported"}"#,
            #"{"ts":"2026-09-18T14:03:12.345+02:00","resolution":null}"#,
            #"{"ts":"2026-09-18T14:03:12.345+02:00","resolution":"command"} trailing"#,
            good,
        ]
        try Self.write(lines.joined(separator: "\n") + "\n", to: directory.url.appending(path: "2026-09-18.jsonl"))

        let page = LogReader(directory: directory.url).read()

        #expect(page.entries.map(\.id) == ["2026-09-18.jsonl:13", "2026-09-18.jsonl:1"])
        #expect(page.unreadableLines == 11)
    }

    /// A line and the entry it reads as. A table of its own: inline, it is too much for the type checker.
    static let partialLines: [(String, LogEntry)] = [
        (
            #"{"ts":"2026-09-18T12:03:12.345Z","resolution":"failed"}"#,
            LogEntry(id: "", timestamp: F.pressedAt, resolution: .failed)
        ),
        (
            #"{"ts":"2026-09-18T14:03:12+02:00","resolution":"discarded","error":"busy"}"#,
            LogEntry(
                id: "", timestamp: Date(timeIntervalSince1970: 1_789_732_992), resolution: .discarded, error: "busy")
        ),
        (
            #"{"ts":"2026-09-18T14:03:12.345+02:00","duration_ms":"12","transcribe_ms":1.5,"raw_text":12,"#
                + #""normalized_text":["a"],"resolution":"command","target_app":{},"action_type":"teleport","#
                + #""exit_code":true,"error":false}"#,
            LogEntry(id: "", timestamp: F.pressedAt, resolution: .command, actionType: "teleport")
        ),
        (
            #"{"ts":"2026-09-18T14:03:12.345+02:00","resolution":"failed","exit_code":2147483648,"extra":1}"#,
            LogEntry(id: "", timestamp: F.pressedAt, resolution: .failed)
        ),
        (
            #"{"ts":"2026-09-18T14:03:12.345+02:00","resolution":"failed","exit_code":-2147483648}"#,
            LogEntry(id: "", timestamp: F.pressedAt, resolution: .failed, exitCode: .min)
        ),
        (
            #"{"ts":"2026-09-18T14:03:12.345+02:00","resolution":"text_inserted","model_tier":"medium"}"#,
            LogEntry(id: "", timestamp: F.pressedAt, resolution: .textInserted, modelTier: "medium")
        ),
        (
            #"{"ts":"2026-09-18T14:03:12.345+02:00","resolution":"text_inserted","model_tier":"turbo"}"#,
            LogEntry(id: "", timestamp: F.pressedAt, resolution: .textInserted, modelTier: "turbo")
        ),
        (
            #"{"ts":"2026-09-18T14:03:12.345+02:00","resolution":"text_inserted","model_tier":3}"#,
            LogEntry(id: "", timestamp: F.pressedAt, resolution: .textInserted)
        ),
        // A line written before `model_tier` existed.
        (
            #"{"ts":"2026-09-18T14:03:12.345+02:00","duration_ms":1800,"transcribe_ms":420,"raw_text":"hi","#
                + #""normalized_text":"hi","resolution":"text_inserted","target_app":"com.apple.mail","#
                + #""action_type":null,"exit_code":null,"error":null}"#,
            LogEntry(
                id: "", timestamp: F.pressedAt, durationMs: 1800, transcribeMs: 420, rawText: "hi",
                normalizedText: "hi", resolution: .textInserted, targetApp: "com.apple.mail")
        ),
        // A line written before `llm_model` and `llm_ms` existed: the eleven keys of M3 to M7.
        (
            #"{"ts":"2026-09-18T14:03:12.345+02:00","duration_ms":1800,"transcribe_ms":420,"raw_text":"hi","#
                + #""normalized_text":"hi","resolution":"text_inserted","target_app":"com.apple.mail","#
                + #""action_type":null,"exit_code":null,"error":null,"model_tier":"small"}"#,
            LogEntry(
                id: "", timestamp: F.pressedAt, durationMs: 1800, transcribeMs: 420, rawText: "hi",
                normalizedText: "hi", resolution: .textInserted, targetApp: "com.apple.mail", modelTier: "small")
        ),
        (
            #"{"ts":"2026-09-18T14:03:12.345+02:00","resolution":"text_clipboard","action_type":"ask","#
                + #""llm_model":"mtplx-bonsai-2-27b-optimized-speed","llm_ms":3420}"#,
            LogEntry(
                id: "", timestamp: F.pressedAt, resolution: .textClipboard, actionType: "ask", llmModel: F.bonsai,
                llmMs: 3_420)
        ),
        (
            #"{"ts":"2026-09-18T14:03:12.345+02:00","resolution":"failed","llm_model":7,"llm_ms":"fast"}"#,
            LogEntry(id: "", timestamp: F.pressedAt, resolution: .failed)
        ),
    ]

    @Test(arguments: partialLines)
    func optionalKeysReadAsNilWhenMissingOrMistyped(_ line: String, _ expected: LogEntry) throws {
        let directory = try TemporaryDirectory()
        try Self.write(line + "\n", to: directory.url.appending(path: "2026-09-18.jsonl"))

        let page = LogReader(directory: directory.url).read()

        #expect(page.unreadableLines == 0)
        #expect(page.entries.map { Self.renamed($0) } == [expected])
    }

    /// Every resolution, with and without an error, and the filters each one passes. Written out, not derived.
    static let filterCases: [(Resolution, String?, Set<LogFilter>)] = [
        (.command, nil, [.all, .commands]),
        (.command, "action_exit", [.all, .commands]),
        (.textInserted, nil, [.all, .text]),
        (.textInserted, "insertion_failed", [.all, .text]),
        (.textClipboard, nil, [.all, .text]),
        (.textClipboard, "insertion_failed", [.all, .text, .errors]),
        (.discarded, nil, [.all]),
        (.discarded, "too_short", [.all]),
        (.failed, nil, [.all, .errors]),
        (.failed, "model_missing:small", [.all, .errors]),
    ]

    @Test func theFilterTableCoversEveryResolutionWithAndWithoutAnError() {
        let covered = Self.filterCases.map { "\($0.0.rawValue):\($0.1 != nil)" }
        let every = Resolution.allCases.flatMap { ["\($0.rawValue):false", "\($0.rawValue):true"] }
        #expect(covered.sorted() == every.sorted())
    }

    @Test(arguments: filterCases)
    func filterIncludes(_ resolution: Resolution, _ error: String?, _ expected: Set<LogFilter>) {
        let entry = LogEntry(id: "", timestamp: F.pressedAt, resolution: resolution, error: error)
        #expect(Set(LogFilter.allCases.filter { $0.includes(entry) }) == expected)
    }

    @Test(arguments: LogFilter.allCases)
    func readAppliesTheFilter(_ filter: LogFilter) throws {
        let directory = try TemporaryDirectory()
        let lines = Self.filterCases.enumerated().map { index, row in
            let error = row.1.map { "\"\($0)\"" } ?? "null"
            return
                #"{"ts":"2026-09-18T14:03:\#(10 + index).000+02:00","resolution":"\#(row.0.rawValue)","error":\#(error)}"#
        }
        try Self.write(lines.joined(separator: "\n") + "\n", to: directory.url.appending(path: "2026-09-18.jsonl"))

        let page = LogReader(directory: directory.url).read(filter: filter)

        let expected = Self.filterCases.indices.reversed().filter { Self.filterCases[$0].2.contains(filter) }
        #expect(page.entries.map(\.id) == expected.map { "2026-09-18.jsonl:\($0 + 1)" })
        #expect(page.unreadableLines == 0)
    }

    /// The older day holds only garbage, so whether it was read shows in `unreadableLines`.
    @Test(arguments: [
        (LogFilter.all, 3, ["2026-09-19.jsonl:3", "2026-09-19.jsonl:2", "2026-09-19.jsonl:1"], 0),
        (.all, 2, ["2026-09-19.jsonl:3", "2026-09-19.jsonl:2"], 0),
        (.commands, 1, ["2026-09-19.jsonl:2"], 0),
        (.all, 4, ["2026-09-19.jsonl:3", "2026-09-19.jsonl:2", "2026-09-19.jsonl:1"], 2),
        (.commands, 2, ["2026-09-19.jsonl:2"], 2),
        (.all, 0, [], 0),
    ])
    func readingStopsOnceTheLimitIsMet(_ filter: LogFilter, _ limit: Int, _ ids: [String], _ unreadable: Int) throws {
        let directory = try TemporaryDirectory()
        let log = UtteranceLog(directory: directory.url, timeZone: F.paris)
        let day = F.beforeMidnight.addingTimeInterval(1)
        log.append(Self.record(at: day, .textInserted))
        log.append(Self.record(at: day.addingTimeInterval(1), .command))
        log.append(Self.record(at: day.addingTimeInterval(2), .discarded(.tooShort)))
        try Self.write("garbage\n{}\n", to: directory.url.appending(path: "2026-09-18.jsonl"))

        let page = LogReader(directory: directory.url).read(filter: filter, limit: limit)

        #expect(page.entries.map(\.id) == ids)
        #expect(page.unreadableLines == unreadable)
    }

    @Test func onlyDayFileNamesAreRead() throws {
        let directory = try TemporaryDirectory()
        let line = Self.record(at: F.pressedAt, .textInserted).jsonLine(timeZone: F.paris) + "\n"
        let ignored = [
            "2099-01-01.jsonl.bak", "2099-01-01.json", "2099-01-01.JSONL", "2099-1-01.jsonl", "2099-01-01-.jsonl",
            "x2099-01-01.jsonl", ".2099-01-01.jsonl", "2099-01-01 .jsonl", "\u{0662}\u{0660}99-01-01.jsonl",
            "notes.jsonl", "commands.yaml",
        ]
        for name in ignored + ["2026-09-18.jsonl"] {
            try Self.write(line, to: directory.url.appending(path: name))
        }

        let reader = LogReader(directory: directory.url)
        let page = reader.read()

        #expect(page.entries.map(\.id) == ["2026-09-18.jsonl:1"])
        #expect(page.unreadableLines == 0)
        #expect(reader.newestFile()?.lastPathComponent == "2026-09-18.jsonl")
    }

    @Test func aMissingDirectoryIsAnEmptyLog() throws {
        let directory = try TemporaryDirectory()
        let missing = LogReader(directory: directory.url.appending(path: "logs", directoryHint: .isDirectory))
        let empty = LogReader(directory: directory.url)

        #expect(missing.read() == .empty)
        #expect(missing.newestFile() == nil)
        #expect(empty.read() == .empty)
        #expect(empty.newestFile() == nil)
    }

    @Test func anEmptyDayFileIsEmpty() throws {
        let directory = try TemporaryDirectory()
        try Self.write("", to: directory.url.appending(path: "2026-09-18.jsonl"))

        let reader = LogReader(directory: directory.url)

        #expect(reader.read() == .empty)
        #expect(reader.newestFile()?.lastPathComponent == "2026-09-18.jsonl")
    }
}
