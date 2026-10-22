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
        var normalized = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        normalized = normalized.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lead = normalized.drop { $0 == " " || $0 == "\t" || $0 == "\n" }
        if lead.isEmpty { return (nil, "") }
        // The marker may be arriving one character at a time.
        if lead == "%" && !complete { return (nil, "") }
        guard lead.hasPrefix(marker) else { return (nil, normalized) }
        let body = lead.dropFirst(marker.count).drop { $0 == " " || $0 == "\t" }
        if let blank = body.range(of: "\n\n") {
            return (intent(body[..<blank.lowerBound]), answer(body[blank.upperBound...]))
        }
        let newlines = body.count { $0 == "\n" }
        guard complete || newlines >= 2 || body.count > maxPendingChars else { return (intent(body), "") }
        guard let end = body.firstIndex(of: "\n") else { return (intent(body), "") }
        return (intent(body[..<end]), answer(body[body.index(after: end)...]))
    }

    /// Its lines joined by one space, cut to the cap; nil when nothing is left.
    private static func intent(_ block: Substring) -> String? {
        let joined = block.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if joined.isEmpty { return nil }
        return joined.count > maxIntentChars ? String(joined.prefix(maxIntentChars - 1)) + "…" : joined
    }

    private static func answer(_ rest: Substring) -> String {
        String(rest.drop { $0 == "\n" })
    }
}
