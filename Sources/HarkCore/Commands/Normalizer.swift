import Foundation

/// The one text form that matching compares, and the log's `normalized_text`.
///
/// In order: lowercase; NFKD, so "ouvré" and "ouvre" collapse and ligatures and full-width forms become plain
/// letters, then lowercase again because compatibility forms such as ℌ or ㎒ decompose to capitals; drop combining
/// marks; spell œ, æ and ß out; remove Whisper's own annotations — `[BLANK_AUDIO]`, `(music)`, `*laughs*` — with the
/// rule the dictation path uses, so both agree on what an annotation is; turn every character that is not a letter or
/// a decimal digit into a space, which covers punctuation, apostrophes, hyphens, NBSP, symbols and emoji; collapse
/// runs of whitespace and trim. The result is idempotent: normalizing it again changes nothing.
public enum Normalizer {
    public static func normalize(_ text: String) -> String {
        let decomposed = text.lowercased().decomposedStringWithCompatibilityMapping.lowercased()
        var spelled = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars where !isCombiningMark(scalar) {
            switch scalar {
            case "œ": spelled.append(contentsOf: "oe".unicodeScalars)
            case "æ": spelled.append(contentsOf: "ae".unicodeScalars)
            case "ß": spelled.append(contentsOf: "ss".unicodeScalars)
            default: spelled.append(scalar)
            }
        }
        let unannotated = HallucinationFilter.strippingAnnotations(String(spelled))
        var words = String.UnicodeScalarView()
        for scalar in unannotated.unicodeScalars {
            words.append(isWordScalar(scalar) ? scalar : " ")
        }
        return String(words).split(separator: " ").joined(separator: " ")
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    /// Letters and decimal digits. The Spacing Modifier Letters block is excluded even though Unicode files it under
    /// letters: once NFKD has turned its superscripts into plain letters, what is left there is ʼ ʻ ˈ and other
    /// apostrophes and accents, which separate words rather than belong to them.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .decimalNumber:
            true
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter:
            true
        case .modifierLetter:
            !(0x02B0...0x02FF).contains(scalar.value)
        default:
            false
        }
    }
}
