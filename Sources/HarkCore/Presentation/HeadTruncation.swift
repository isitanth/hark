/// Fits the live transcript into the HUD's single line by dropping its head, so the newest words stay visible
/// while the user is still speaking.
///
/// HarkApp passes a budget of 44 characters and keeps `.truncationMode(.head)` only as a guard for wide glyphs;
/// the word-boundary rule lives here so it can be tested. Counting is in `Character`s, so a grapheme cluster
/// (a combining accent, a ZWJ emoji) is never split. Only ASCII space, tab, newline and carriage return break
/// words: U+00A0 and U+202F bind French punctuation to the word before it, so "mot :" never leaves ": " at the
/// head of the line.
public enum HeadTruncation {
    private static let ellipsis: Character = "\u{2026}"

    public static func fit(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters >= 2 else { return "" }
        let words = text.split(whereSeparator: isBreak)
        let collapsed = words.joined(separator: " ")
        if collapsed.count <= maxCharacters { return collapsed }

        var kept: [Substring] = []
        var length = 1
        for word in words.reversed() {
            let added = length + 1 + word.count
            if added > maxCharacters { break }
            kept.append(word)
            length = added
        }
        guard !kept.isEmpty else {
            return String(ellipsis) + String(collapsed.suffix(maxCharacters - 1))
        }
        return String(ellipsis) + " " + kept.reversed().joined(separator: " ")
    }

    private static func isBreak(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r" || character == "\r\n"
    }
}
