import Foundation
import os

/// One line of the utterance log, read back. The same thirteen keys as `UtteranceRecord`, decoded rather than built.
/// A line written before `model_tier`, or before `llm_model` and `llm_ms`, reads with them nil.
public struct LogEntry: Sendable, Equatable, Identifiable {
    /// `<file name>:<line number>` for a line read from disk, `live:<ts>` for one built from a record in memory.
    public let id: String
    public let timestamp: Date
    public let durationMs: Int?
    public let transcribeMs: Int?
    public let rawText: String?
    public let normalizedText: String?
    public let resolution: Resolution
    public let targetApp: String?
    /// The raw `action_type` string, kept even if this build does not know the action.
    public let actionType: String?
    public let exitCode: Int32?
    public let error: String?
    /// The raw `model_tier` string, kept even if this build does not know the tier.
    public let modelTier: String?
    public let llmModel: String?
    public let llmMs: Int?

    /// The line of an ask, about a selection or to the assistant: its text is the instruction, not what was typed.
    public var isAsk: Bool { actionType == LoggedAction.askRawValue }

    /// The time the panel shows beside the outcome: the model's for an ask, else the transcription's.
    public var shownMs: Int? { isAsk ? llmMs : transcribeMs }

    public init(
        id: String, timestamp: Date, durationMs: Int? = nil, transcribeMs: Int? = nil, rawText: String? = nil,
        normalizedText: String? = nil, resolution: Resolution, targetApp: String? = nil, actionType: String? = nil,
        exitCode: Int32? = nil, error: String? = nil, modelTier: String? = nil, llmModel: String? = nil,
        llmMs: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.durationMs = durationMs
        self.transcribeMs = transcribeMs
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.resolution = resolution
        self.targetApp = targetApp
        self.actionType = actionType
        self.exitCode = exitCode
        self.error = error
        self.modelTier = modelTier
        self.llmModel = llmModel
        self.llmMs = llmMs
    }

    /// Marks an entry built from a record in this run, as opposed to a line read from disk.
    public static let liveIDPrefix = "live:"

    /// The entry a record would read back as, for the one the pipeline has just written. The timestamp is the one
    /// the log keeps, to the millisecond, so this entry and the same line read from disk compare equal: `RecentFeed`
    /// deduplicates on it when the launch seed arrives after the first utterance.
    public init(record: UtteranceRecord) {
        self.init(
            id: Self.liveIDPrefix + "\(record.timestamp.timeIntervalSince1970)",
            timestamp: LogReader.loggedTimestamp(record.timestamp),
            durationMs: record.durationMs, transcribeMs: record.transcribeMs, rawText: record.rawText,
            normalizedText: record.normalizedText, resolution: record.resolution, targetApp: record.targetApp,
            actionType: record.actionType?.rawValue, exitCode: record.exitCode, error: record.error,
            modelTier: record.modelTier?.rawValue, llmModel: record.llmModel, llmMs: record.llmMs)
    }
}

/// The Log tab's filter.
public enum LogFilter: String, Sendable, CaseIterable {
    case all
    /// `command`.
    case commands
    /// `text_inserted` and `text_clipboard`.
    case text
    /// `failed`, and `text_clipboard` with an `error`: text that only reached the clipboard because insertion failed.
    /// Discards are not errors — a tap too short to be speech is the pipeline working.
    case errors

    public func includes(_ entry: LogEntry) -> Bool {
        switch self {
        case .all: true
        case .commands: entry.resolution == .command
        case .text: entry.resolution == .textInserted || entry.resolution == .textClipboard
        case .errors: entry.resolution == .failed || (entry.resolution == .textClipboard && entry.error != nil)
        }
    }
}

public struct LogPage: Sendable, Equatable {
    /// Newest first.
    public let entries: [LogEntry]
    /// Complete lines that did not decode, among those read to fill the page. A trailing line with no newline is still
    /// being written and is not counted.
    public let unreadableLines: Int

    public init(entries: [LogEntry], unreadableLines: Int) {
        self.entries = entries
        self.unreadableLines = unreadableLines
    }

    public static let empty = LogPage(entries: [], unreadableLines: 0)
}

/// Reads `<directory>/YYYY-MM-DD.jsonl`, newest day first, newest line first within a day.
public struct LogReader: Sendable {
    public let directory: URL

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "log-reader")

    public init(directory: URL) {
        self.directory = directory
    }

    /// Up to `limit` entries that pass `filter`, newest first, reading only as many day files as that takes.
    ///
    /// Reading stops at the `limit`th match, so `unreadableLines` counts only the lines read to fill the page.
    public func read(filter: LogFilter = .all, limit: Int = 500) -> LogPage {
        guard limit > 0 else { return .empty }
        let decoder = JSONDecoder()
        var entries: [LogEntry] = []
        var unreadable = 0
        for file in dayFiles() {
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                Self.logger.error("cannot read \(file.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            // UtteranceLog writes each line and its newline in one write(2). The last piece is either the empty
            // tail after the final newline or a line still being written; neither is a line to read.
            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            lines.removeLast()
            for (index, line) in lines.enumerated().reversed() {
                guard let fields = try? decoder.decode(LogLine.self, from: Data(line)) else {
                    unreadable += 1
                    continue
                }
                let entry = fields.entry(id: "\(file.lastPathComponent):\(index + 1)")
                guard filter.includes(entry) else { continue }
                entries.append(entry)
                if entries.count == limit { return LogPage(entries: entries, unreadableLines: unreadable) }
            }
        }
        return LogPage(entries: entries, unreadableLines: unreadable)
    }

    /// The newest day file, if there is one. What "Reveal in Finder" selects.
    public func newestFile() -> URL? {
        dayFiles().first
    }

    /// `YYYY-MM-DD.jsonl` and nothing else: ASCII digits, so the names sort as the days do.
    static func isDayFileName(_ name: String) -> Bool {
        name.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}\.jsonl/) != nil
    }

    /// What `ts` reads back as. The written form keeps milliseconds and drops the rest, so a record's own timestamp
    /// is almost never equal to it; going through the same format is what makes the two compare equal.
    static func loggedTimestamp(_ date: Date) -> Date {
        let style = UtteranceRecord.timestampStyle(.gmt)
        return (try? style.parse(style.format(date))) ?? date
    }

    /// Newest first. A missing directory is a log nobody has written yet.
    private func dayFiles() -> [URL] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            Self.logger.error("cannot list \(directory.path(percentEncoded: false)): \(error.localizedDescription)")
            return []
        }
        return names.filter(Self.isDayFileName).sorted(by: >).map {
            directory.appending(path: $0, directoryHint: .notDirectory)
        }
    }
}

/// One decoded line. `ts` and `resolution` make a line readable; any other key with the wrong type reads as nil
/// rather than costing the whole line.
private struct LogLine: Decodable {
    let timestamp: Date
    let durationMs: Int?
    let transcribeMs: Int?
    let rawText: String?
    let normalizedText: String?
    let resolution: Resolution
    let targetApp: String?
    let actionType: String?
    let exitCode: Int32?
    let error: String?
    let modelTier: String?
    let llmModel: String?
    let llmMs: Int?

    private enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case durationMs = "duration_ms"
        case transcribeMs = "transcribe_ms"
        case rawText = "raw_text"
        case normalizedText = "normalized_text"
        case resolution
        case targetApp = "target_app"
        case actionType = "action_type"
        case exitCode = "exit_code"
        case error
        case modelTier = "model_tier"
        case llmModel = "llm_model"
        case llmMs = "llm_ms"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ts = try container.decode(String.self, forKey: .timestamp)
        timestamp = try UtteranceRecord.timestampStyle(.gmt).parse(ts)
        let resolution = try container.decode(String.self, forKey: .resolution)
        guard let known = Resolution(rawValue: resolution) else {
            throw DecodingError.dataCorruptedError(
                forKey: .resolution, in: container, debugDescription: "unknown resolution \(resolution)")
        }
        self.resolution = known
        durationMs = try? container.decodeIfPresent(Int.self, forKey: .durationMs)
        transcribeMs = try? container.decodeIfPresent(Int.self, forKey: .transcribeMs)
        rawText = try? container.decodeIfPresent(String.self, forKey: .rawText)
        normalizedText = try? container.decodeIfPresent(String.self, forKey: .normalizedText)
        targetApp = try? container.decodeIfPresent(String.self, forKey: .targetApp)
        actionType = try? container.decodeIfPresent(String.self, forKey: .actionType)
        exitCode = try? container.decodeIfPresent(Int32.self, forKey: .exitCode)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        modelTier = try? container.decodeIfPresent(String.self, forKey: .modelTier)
        llmModel = try? container.decodeIfPresent(String.self, forKey: .llmModel)
        llmMs = try? container.decodeIfPresent(Int.self, forKey: .llmMs)
    }

    func entry(id: String) -> LogEntry {
        LogEntry(
            id: id, timestamp: timestamp, durationMs: durationMs, transcribeMs: transcribeMs, rawText: rawText,
            normalizedText: normalizedText, resolution: resolution, targetApp: targetApp, actionType: actionType,
            exitCode: exitCode, error: error, modelTier: modelTier, llmModel: llmModel, llmMs: llmMs)
    }
}

extension LogEntry {
    /// Something was heard and the line keeps it out, because a password field had focus. Every transcript names its
    /// model, so text missing beside a model tier was withheld, not absent — whatever the utterance became, a command
    /// included. A copy from a password field says so on its own, for lines older than `model_tier`.
    public var hidesTranscript: Bool {
        rawText == nil && (modelTier != nil || EntryOutcome(self) == .copied(.secureField))
    }
}
