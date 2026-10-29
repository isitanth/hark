import CoreGraphics
import Foundation

// The reader's patterns and constants (M13.3), ported verbatim from the V2F prototype (run_v2.py, run_v2f.py,
// rows_for_lines.py, glyph_codes.py, harness.parse_number). Frozen for M13.0: only the held-out ablation changes them.

enum ReaderVocabulary {
    /// A numeric column is one where at least this share of the non-empty single cells are clean numbers.
    static let numericShare = 0.5 as CGFloat
    /// Two free lines join a row when their centres lie within this share of the smaller line height.
    static let rowTolerance = 0.35 as CGFloat
    /// A code column needs this many rows ending in one capital.
    static let codeRows = 2
    /// Crops read at once.
    static let cropsInFlight = 8
    /// The longest side the reader gets: a larger raster is scaled down first.
    static let inputCap = 4096

    /// `NUM_CLEAN`: one number, its sign, parentheses, a currency or a unit, nothing else.
    static let numClean = regex(
        #"^\s*[-−+]?\s*\(?\s*(?:[€$£]\s*)?[-−]?(?:\d{1,3}(?:[   ,.]\d{3})*|\d{4,})(?:[.,]\d+)?"#
            + #"\s*(?:[€$£%]|p|h|kg|g|EUR|USD|GBP)?\s*\)?\s*$"#)
    /// Anything outside Latin-1 and the symbols a document uses: the `ą ł š Ś` Vision appends.
    static let suspicious = regex(#"[^\x00-\xFF€−–—•·’‘“”…›‹▾×→←°№]"#)
    static let decimalsTail = regex(#"[.,](\d+)\s*(?:[€$£%]|p|h)?\s*\)?\s*$"#)
    static let word = regex(#"[A-Za-zÀ-ÿ]{3,}"#)
    static let digit = regex(#"\d"#)
    static let codeLetter = regex(#"^[A-Z]$"#)
    /// `(.+?)\s+([A-Z])`, whole: a number followed by one code letter.
    static let numberAndCode = regex(#"^(.+?)\s+([A-Z])$"#)

    static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("a reader pattern does not compile: \(pattern)")
        }
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isClean(_ text: String) -> Bool { matches(numClean, text) }
    static func isSuspicious(_ text: String) -> Bool { matches(suspicious, text) }
    static func hasDigit(_ text: String) -> Bool { matches(digit, text) }
    static func hasWord(_ text: String) -> Bool { matches(word, text) }
    static func isCodeLetter(_ text: String) -> Bool {
        matches(codeLetter, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The decimals a number shows: `1 234,56 €` 2, `7,5 h` 1, `12` 0.
    static func decimals(_ text: String) -> Int {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = decimalsTail.firstMatch(in: text, range: range),
            let group = Range(match.range(at: 1), in: text)
        else { return 0 }
        return text[group].unicodeScalars.count
    }

    /// The digits of a text, every other character dropped.
    static func digits(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.numericType == .decimal }))
    }

    /// The digits of a garbled read before its first suspicious character: `£21,32łł` gives `2132`.
    static func cleanPrefix(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = suspicious.firstMatch(in: text, range: range),
            let cut = Range(match.range, in: text)
        else { return digits(text) }
        return digits(String(text[..<cut.lowerBound]))
    }

    /// Cyrillic `З` and `О` read where a `3` and a `0` stand.
    static func replacingHomoglyphs(_ text: String) -> String {
        let map: [Unicode.Scalar: Unicode.Scalar] = ["З": "3", "з": "3", "О": "0", "о": "0"]
        return String(String.UnicodeScalarView(text.unicodeScalars.map { map[$0] ?? $0 }))
    }

    /// The number and the code letter of a read such as `3,79 A`.
    static func numberAndCode(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = numberAndCode.firstMatch(in: trimmed, range: range),
            let group = Range(match.range(at: 1), in: trimmed)
        else { return nil }
        return String(trimmed[group])
    }
}

// R8's own number parser: harness.parse_number with `lang` "fr", kept private to the reader for parity with V2F.
// S1's DisplayedNumber reads the document's convention instead; R8 keeps the measured one.
extension ReaderVocabulary {
    private static let separator = #"[   .,'’]"#
    private static let number = regex(
        #"(?<sign>[-−–])?\s*(?:[€$£]|EUR|USD|GBP|CHF)?\s*(?<paren>\()?\s*(?:[€$£]|CHF)?\s*"#
            + #"(?<num>\d{1,3}(?:"# + separator + #"\d{3})+(?:[.,]\d+)?(?!\d)|\d+(?:[.,]\d+)?)"#)
    private static let closingParen = regex(#"^\s*(?:[€$£]|EUR|USD|GBP|CHF)?\s*\)"#)
    private static let hours = regex(#"^\s?h(?:\s?(\d{2}))?(?![A-Za-zÀ-ÿ\d])"#)
    private static let kilo = regex(#"^\s?[kK](?![A-Za-zÀ-ÿ])"#)
    private static let grouped = regex(
        #"^(\d{1,3})((?:"# + separator + #"\d{3})+)([.,]\d+)?$"#)
    private static let separators = regex(separator)
    private static let allDigits = regex(#"^\d+$"#)

    /// The first number of a text, French style: a lone `1,234` is 1.234. Nil when there is none.
    static func frenchNumber(_ text: String) -> Decimal? {
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = number.firstMatch(in: text, range: whole),
            let numRange = Range(match.range(withName: "num"), in: text),
            let end = Range(match.range, in: text)?.upperBound
        else { return nil }
        let num = String(text[numRange])
        let rest = String(text[end...])
        let negative =
            match.range(withName: "sign").location != NSNotFound
            || (match.range(withName: "paren").location != NSNotFound && matches(closingParen, rest))
        let restRange = NSRange(rest.startIndex..., in: rest)
        if matches(allDigits, num), let hour = hours.firstMatch(in: rest, range: restRange) {
            var value = plainDecimal(num) ?? 0
            if let minutes = Range(hour.range(at: 1), in: rest), let m = plainDecimal(String(rest[minutes])) {
                value += m / 60
            }
            return negative ? -value : value
        }
        let isKilo = matches(kilo, rest)
        let normalized: String
        let numWhole = NSRange(num.startIndex..., in: num)
        if let group = grouped.firstMatch(in: num, range: numWhole),
            let head = Range(group.range(at: 1), in: num), let tail = Range(group.range(at: 2), in: num)
        {
            let groups = String(num[tail])
            let groupSeparator = groups.first
            let joined = String(num[head]) + groups
            let bare = separators.stringByReplacingMatches(
                in: joined, range: NSRange(joined.startIndex..., in: joined), withTemplate: "")
            let fraction = Range(group.range(at: 3), in: num).map { String(num[$0]) }
            if let fraction, fraction.first != groupSeparator {
                normalized = bare + "." + fraction.dropFirst()
            } else if fraction != nil {
                return nil
            } else if groupSeparator == ",", groups.unicodeScalars.count == 4 {
                normalized = String(num[head]) + "." + groups.dropFirst()
            } else {
                normalized = bare
            }
        } else {
            normalized = num.replacingOccurrences(of: ",", with: ".")
        }
        guard var value = plainDecimal(normalized) else { return nil }
        if isKilo { value *= 1000 }
        return negative ? -value : value
    }

    /// `123.45` as an exact Decimal, built digit by digit.
    static func plainDecimal(_ text: String) -> Decimal? {
        var significand = Decimal(0)
        var exponent = 0
        var seenPoint = false
        var seenDigit = false
        for character in text {
            if character == "." {
                guard !seenPoint else { return nil }
                seenPoint = true
            } else if let digit = character.wholeNumberValue, character.isNumber {
                significand = significand * 10 + Decimal(digit)
                seenDigit = true
                if seenPoint { exponent -= 1 }
            } else {
                return nil
            }
        }
        guard seenDigit else { return nil }
        return Decimal(sign: .plus, exponent: exponent, significand: significand)
    }
}
