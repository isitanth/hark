import Foundation

/// One line of the utterance log. The field set is the contract in CLAUDE.md: exactly these eleven keys,
/// in this order, with nil written as `null`.
public struct UtteranceRecord: Sendable, Equatable {
    public static let keys = [
        "ts", "duration_ms", "transcribe_ms", "raw_text", "normalized_text",
        "resolution", "target_app", "action_type", "exit_code", "error", "model_tier",
    ]

    /// Key-down time. Written as `ts`, and picks the day file.
    public let timestamp: Date
    public let durationMs: Int?
    public let transcribeMs: Int?
    public let rawText: String?
    public let normalizedText: String?
    public let resolution: Resolution
    public let targetApp: String
    public let actionType: ActionType?
    public let exitCode: Int32?
    public let error: String?
    /// The tier that produced the transcript. Nil when there is none: a discard before transcription, a missing
    /// model, a decode that failed.
    public let modelTier: ModelTier?

    public init(context: UtteranceContext, transcript: Transcript?, outcome: PipelineOutcome) {
        timestamp = context.pressedAt
        if let capture = context.capture {
            durationMs = capture.durationMs
        } else if let releasedAt = context.releasedAt {
            durationMs = Int((releasedAt.timeIntervalSince(context.pressedAt) * 1000).rounded())
        } else {
            durationMs = nil
        }
        transcribeMs = context.transcribeMs

        let secure = context.focus?.isSecureInput ?? false
        rawText = secure ? nil : transcript?.raw
        normalizedText = secure ? nil : transcript?.normalized

        resolution = outcome.resolution
        targetApp = context.focus?.app?.logName ?? "unknown"
        actionType = context.action
        modelTier = transcript?.tier

        // A capture cut at the length limit is something that went wrong, and the one thing that can go wrong on a
        // line whose text went through: `command` and `text_inserted` carry it. A clipboard reason, a discard or a
        // failure is the bigger fact and keeps the field; `duration_ms` at the limit still tells.
        let cut = context.capture?.reachedMaxDuration == true ? DiscardReason.maxDuration.rawValue : nil
        switch outcome {
        case .command:
            exitCode = 0
            error = cut
        case .textInserted:
            exitCode = nil
            error = cut
        case .textClipboard(let reason):
            exitCode = nil
            error = reason.code
        case .discarded(let reason):
            exitCode = nil
            error = reason.rawValue
        case .failed(let failure):
            if case .actionExit(let code) = failure { exitCode = code } else { exitCode = nil }
            error = failure.code
        }
    }

    /// The JSONL line, without the trailing newline. `ts` is ISO 8601 with milliseconds and the offset of `timeZone`.
    public func jsonLine(timeZone: TimeZone) -> String {
        let values: [JSONScalar] = [
            .string(Self.timestampStyle(timeZone).format(timestamp)),
            .int(durationMs.map(Int64.init)),
            .int(transcribeMs.map(Int64.init)),
            .string(rawText),
            .string(normalizedText),
            .string(resolution.rawValue),
            .string(targetApp),
            .string(actionType?.rawValue),
            .int(exitCode.map(Int64.init)),
            .string(error),
            .string(modelTier?.rawValue),
        ]
        let fields = zip(Self.keys, values).map { "\"\($0)\":\($1.encoded)" }
        return "{" + fields.joined(separator: ",") + "}"
    }

    static func timestampStyle(_ timeZone: TimeZone) -> Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: timeZone)
    }
}

private enum JSONScalar {
    case string(String?)
    case int(Int64?)

    var encoded: String {
        switch self {
        case .string(let value?): Self.quote(value)
        case .int(let value?): String(value)
        case .string(nil), .int(nil): "null"
        }
    }

    private static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029:
                out += "\\u" + String(scalar.value, radix: 16, uppercase: true).leftPadded(to: 4)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension String {
    fileprivate func leftPadded(to width: Int) -> String {
        String(repeating: "0", count: max(0, width - count)) + self
    }
}
