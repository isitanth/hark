import Foundation

/// What Hark says outside its own windows. Typed, so HarkCore decides what to say and HarkApp only words it.
public enum NotificationContent: Sendable, Equatable {
    /// `tier` was selected because it was the only installed model and none was selected.
    case modelAutoSelected(ModelTier)
    /// Dictated text is on the clipboard. `preview` is the first graphemes of what was said, nil when it came from
    /// a password field and must not be shown anywhere. `fallback` means the text was meant for a field and did not
    /// get there, as opposed to the clipboard being where the user asked it to go.
    case textCopied(preview: String?, fallback: Bool, sound: Bool)
    /// The capture stopped at the length limit while the key was still held, and what was said until then went
    /// through. `minutes` is the limit as the line recorded it.
    case captureCut(minutes: Int, sound: Bool)
    /// The input device changed while the key was held. The recording was cancelled and nothing was kept.
    case inputChanged(sound: Bool)
    /// A voice command that did not do what it said. `reason` is the line's `error` read back, carrying the app name
    /// when the line has one; `code` is that `error` as written.
    case commandFailed(EntryOutcome.FailureReason, code: String, sound: Bool)
}

/// Whether a notification reached the user. `denied` is the user's choice in System Settings, which becomes a
/// health warning; `failed` is anything else, such as a process with no bundle to post from.
public enum NotificationDelivery: Sendable, Equatable {
    case delivered
    case denied
    case failed
}

/// Turns the log line an utterance has just written into the notification the user sees, or nothing. Pure: the
/// wording is HarkApp's, and so is the decision to post it at all.
public enum ClipboardNotice {
    /// How much of the transcript the body shows. Enough to recognise the sentence, short enough for a banner.
    public static let previewLimit = 40

    /// Nil unless the text ended on the clipboard and the user asked to be told.
    ///
    /// A `text_clipboard` line writes an `error` exactly when the clipboard is not where the user asked the text to
    /// go, so that is the fallback. A password field the user sent to the clipboard on purpose is not one.
    ///
    /// An ask's Copy is a click in the popup, which is answer enough. An ask's text on the clipboard for another
    /// reason is told without a preview: the line's text is the instruction, not what was copied.
    public static func content(for record: UtteranceRecord, style: NotificationStyle) -> NotificationContent? {
        guard style != .off, record.resolution == .textClipboard else { return nil }
        let ask = record.actionType == .ask
        if ask, record.error == nil { return nil }
        return .textCopied(
            preview: ask ? nil : record.rawText.map(preview), fallback: record.error != nil, sound: style == .standard)
    }

    /// The first `previewLimit` graphemes, with an ellipsis when there is more. Whitespace is collapsed first: a
    /// banner shows one line, and a line break in the middle of a sentence would cost most of it.
    public static func preview(_ text: String) -> String {
        let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard cleaned.count > previewLimit else { return cleaned }
        return cleaned.prefix(previewLimit) + "…"
    }
}

/// The other outcome with nothing on screen to explain it: a capture that hit the length limit while the key was
/// still held. The text went through, but the sentence ends where the limit fell.
public enum CaptureLimitNotice {
    /// Nil unless the line says `max_duration` on text that went through, and the user asked to be told.
    public static func content(for record: UtteranceRecord, style: NotificationStyle) -> NotificationContent? {
        guard style != .off, record.error == DiscardReason.maxDuration.rawValue,
            record.resolution == .textInserted || record.resolution == .command,
            let durationMs = record.durationMs
        else { return nil }
        return .captureCut(minutes: durationMs / 60_000, sound: style == .standard)
    }
}

/// A recording cancelled because the microphone changed under it: the line is `failed` / `device_changed`, and
/// nothing on screen says why the words went nowhere.
public enum InputChangeNotice {
    /// Nil unless the line failed on a device change and the user asked to be told.
    public static func content(for record: UtteranceRecord, style: NotificationStyle) -> NotificationContent? {
        guard style != .off, record.resolution == .failed, record.error == PipelineFailure.deviceChanged.code
        else { return nil }
        return .inputChanged(sound: style == .standard)
    }
}

/// A command that failed: the app was not found, quit as soon as it opened, or the action did not start or finish.
/// The words went nowhere and the panel is closed. An app that opened behind the one in front is not one: it opened.
public enum CommandFailureNotice {
    /// Nil unless the line failed on one of those codes and the user asked to be told.
    public static func content(for record: UtteranceRecord, style: NotificationStyle) -> NotificationContent? {
        guard style != .off, record.resolution == .failed, let code = record.error else { return nil }
        let reason = EntryOutcome.failureReason(code)
        switch reason {
        case .appNotFound, .appExited, .actionTimeout, .actionLaunch:
            return .commandFailed(reason, code: code, sound: style == .standard)
        default:
            return nil
        }
    }
}
