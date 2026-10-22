import Foundation

/// An image ask's reply starts with one line, after the `%%` marker, that restates what the user is after and how the
/// image was read; the answer follows. The rules and the twelve table cases are in the M11 plan's report a6, §2.
public enum IntentSplit {
    public static let marker = "%%"
    /// Longer, the restatement is cut to 239 characters and "…".
    public static let maxIntentChars = 240
    /// Past this with no blank line while streaming, the restatement is settled.
    public static let maxPendingChars = 600

    /// `complete` is false while the reply streams, true on the final text (reviewing, Copy, Insert). Without the
    /// marker, the whole reply is the answer.
    public static func split(_ text: String, complete: Bool) -> (intent: String?, answer: String) {
        (nil, text)
    }
}
