import Foundation

/// Whether an AX insertion landed, judged from what the field reports afterwards.
public enum AXInsertionVerdict: String, Sendable, Equatable {
    /// The field shows the text went in.
    case confirmed
    /// The field shows nothing happened: the set was refused, or accepted and ignored. The inserter pastes instead.
    case absent
    /// The set succeeded and the field cannot say more, or it changed in a way that does not match the text (a
    /// rewrite of a different length, the user typing). Pasting on top could type the text twice, so it stands.
    case unverified
    /// The set timed out and the field does not show the text yet. The app may still apply it, so it is neither
    /// pasted nor counted as inserted: the text goes to the clipboard.
    case uncertain
}

extension AXInsertionReport {
    /// Offsets are UTF-16, as the Accessibility API counts. Measured in TextEdit: after inserting n units at a caret at
    /// L, the selection is (L + n, 0), the count grows by n minus the replaced length, and the string read at L is the
    /// text, emoji and curly quotes included.
    ///
    /// An exact match of the count or the caret confirms. Otherwise, any sign that the field changed rules out a paste,
    /// because a field that rewrites the text on the way in ("..." to "…") took it; only a field where nothing moved
    /// is absent. The read-back string is the last resort, used only when the field reports neither count nor caret:
    /// inserting "the" in front of "the" reads back the same either way.
    public func verdict(for text: String) -> AXInsertionVerdict {
        guard setSucceeded || timedOut else { return .absent }
        let length = text.utf16.count

        var count: (confirms: Bool, changed: Bool, still: Bool)?
        if let countBefore = before.characterCount, let countAfter = after.characterCount {
            // A replacement of the same length leaves the count alone whether or not it happened.
            let telling = before.selectionLength.map { $0 != length } ?? false
            let replaced = before.selectionLength ?? 0
            count = (
                telling && countAfter == countBefore - replaced + length, countAfter != countBefore,
                telling && countAfter == countBefore
            )
        }
        var caret: (confirms: Bool, moved: Bool)?
        if let location = before.selectionLocation, let replaced = before.selectionLength,
            let position = after.selectionLocation, let selected = after.selectionLength
        {
            caret = (position == location + length && selected == 0, !(position == location && selected == replaced))
        }

        if count?.confirms == true || caret?.confirms == true { return .confirmed }
        if timedOut { return .uncertain }
        if count?.changed == true || caret?.moved == true { return .unverified }
        if count?.still == true || caret != nil { return .absent }
        if let readBack { return readBack == text ? .confirmed : .absent }
        return .unverified
    }
}
