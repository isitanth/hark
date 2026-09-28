import Foundation

/// Whether a dictation needs a space in front of it, given the character it is landing after.
///
/// Two dictations in a row into the same field gave "Hello there.Next sentence." Whisper punctuates but does not
/// know what is already in the field, so the space has to come from here — and only when the field says what is
/// before the caret. At the start of a field, after whitespace, or in an app that does not answer, the text goes in
/// exactly as it was heard.
public enum InsertionSpacing {
    /// Punctuation that ends what comes before it. After one of these a new dictation is a new word; a dictation
    /// that starts with one belongs to the word already there, so it gets no space either.
    ///
    /// The straight quote `"` is not here: it opens as often as it closes, and guessing wrong is worse than
    /// leaving it alone. Neither is the apostrophe, straight or curly — in `l’` and `don’t` it joins two words
    /// rather than ending one, and that is what it is nearly always doing.
    public static let closingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "%", ")", "]", "}", "”", "»", "…",
    ]

    /// `previous` is the character immediately before the caret, or nil when the field did not say.
    public static func needsSpace(after previous: Character?, before text: String) -> Bool {
        guard let previous, previous.isLetter || previous.isNumber || closingPunctuation.contains(previous) else {
            return false
        }
        guard let first = text.first, !first.isWhitespace, !closingPunctuation.contains(first) else { return false }
        return true
    }

    /// The text as it should reach the field.
    public static func spaced(_ text: String, after previous: Character?) -> String {
        needsSpace(after: previous, before: text) ? " " + text : text
    }
}
