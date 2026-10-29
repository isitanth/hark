import Foundation

// The number parser (M13, b2 §3). S1 implements this.

/// What a number on screen carries besides its value.
public enum AmountNote: String, Hashable, Sendable, CaseIterable {
    /// Read through a character the reader is unsure of.
    case doubt
    /// A lone dash in an amount column, read as zero.
    case dashAsZero
    /// `~`, `≈`, `ca.`, `about`.
    case approximate
    /// The separators were decided by the currency or the Mac's locale, not by the document.
    case assumedConvention
    /// Accounting parentheses: `(1,240)` is −1240.
    case parenthesized
    /// `85p`, read as 0.85 of the pound.
    case pence
}

/// One number as displayed, decoded exactly.
public struct Amount: Sendable, Equatable {
    /// Sign, pence and `k`/`M` applied.
    public var value: Decimal
    public var unit: CellUnit
    /// Decimals as displayed, after pence conversion: `85p` is 2.
    public var scale: Int
    public var notes: Set<AmountNote>

    public init(value: Decimal, unit: CellUnit, scale: Int, notes: Set<AmountNote> = []) {
        self.value = value
        self.unit = unit
        self.scale = scale
        self.notes = notes
    }
}

/// What one item of the sheet holds.
public enum CellReading: Sendable, Equatable {
    case amount(Amount)
    /// Words, a date, a code: no number to compute with.
    case text
    /// Digits glued to stray letters: misread, never a shorter number.
    case garbled
}

/// What a token cannot decide alone (b2 §3.4, §3.5): the caller passes what the rest of the frame says.
public struct ReadingContext: Sendable, Equatable {
    /// The decimal separator its column's unambiguous numbers use, if they agree (step 3).
    public var columnDecimal: Character?
    /// The region's vote (step 4).
    public var region: NumberConvention?
    /// A table cell rather than a free line.
    public var inTable: Bool
    /// Its column holds amounts.
    public var columnHoldsAmounts: Bool
    /// Its column shows signs, so an unsigned number in it is positive by choice.
    public var columnSigned: Bool
    /// The currency the region writes, when it writes one.
    public var currency: Currency?
    /// The Mac's decimal separator, read by the app (step 6). HarkCore reads no locale of its own.
    public var macDecimal: Character

    public init(
        columnDecimal: Character? = nil, region: NumberConvention? = nil, inTable: Bool = false,
        columnHoldsAmounts: Bool = false, columnSigned: Bool = false, currency: Currency? = nil,
        macDecimal: Character = "."
    ) {
        self.columnDecimal = columnDecimal
        self.region = region
        self.inTable = inTable
        self.columnHoldsAmounts = columnHoldsAmounts
        self.columnSigned = columnSigned
        self.currency = currency
        self.macDecimal = macDecimal
    }
}

/// One item's text and where it sits, for the region's vote.
public struct ColumnText: Sendable, Equatable {
    public var text: String
    public var table: Int?
    public var column: Int?

    public init(text: String, table: Int?, column: Int?) {
        self.text = text
        self.table = table
        self.column = column
    }
}

/// Which of b2 §3.4's steps decided a number's separators.
public enum SeparatorStep: Int, Sendable, CaseIterable {
    /// The token alone: both marks, a repeated mark, a space, or not three digits after the mark.
    case token = 1
    /// A plain amount whose currency has fewer than three minor units: the mark groups (`£18,450`).
    case currencyMinorUnits
    case column
    case region
    /// `€` means a decimal comma; `$ £ ¥ CHF` a decimal point.
    case currency
    /// The Mac's own separator, noted as assumed.
    case macLocale
}

/// Reads the numbers a document displays, in its own separators: never a locale literal, never binary floating point.
public enum DisplayedNumber {
    static let spaceLike: Set<Character> = [
        " ", "\u{00A0}", "\u{202F}", "\u{2009}", "\u{2007}", "\u{2008}", "\u{200A}",
    ]
    static let apostrophes: Set<Character> = ["'", "\u{2019}"]
    static let minusSigns: Set<Character> = ["-", "\u{2212}", "\u{2013}", "\u{2012}", "\u{FE63}", "\u{FF0D}"]
    static let dashes: Set<Character> = ["-", "\u{2212}", "\u{2013}", "\u{2014}", "\u{2012}"]
    /// The most significant digits a Decimal holds exactly.
    static let maxDigits = 38

    /// The amounts in one item's text, in order: what the sheet builder splits on (one ID, one number). Each range
    /// covers the sign, the currency and the unit suffix. `harness.split_amounts`'s rule, frozen in M13.0.
    public static func amounts(in text: String) -> [Range<String.Index>] {
        let normalized = normalize(text)
        return tokens(in: normalized).map { token in
            let start = text.index(text.startIndex, offsetBy: token.start)
            let end = text.index(text.startIndex, offsetBy: token.spanEnd)
            return start..<end
        }
    }

    /// A text holding two amounts or more, as one part per amount, each keeping the words before it; one amount or
    /// none, the text unchanged.
    public static func split(_ text: String) -> [String] {
        let ranges = amounts(in: text)
        guard ranges.count >= 2 else { return [text] }
        let cuts = [text.startIndex] + ranges.dropLast().map(\.upperBound) + [text.endIndex]
        return zip(cuts, cuts.dropFirst()).compactMap { start, end in
            let words = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return words.isEmpty ? nil : words
        }
    }

    /// One item, read in its context.
    public static func read(_ text: String, context: ReadingContext) -> CellReading {
        reading(text, context: context).reading
    }

    /// The parser's thin entry for a value alone.
    public static func parse(_ text: String, convention: NumberConvention) -> Decimal? {
        guard case .amount(let amount) = read(text, context: ReadingContext(region: convention)) else { return nil }
        return amount.value
    }

    /// One item, with the step that decided its separators (nil when no separator needed deciding).
    public static func reading(_ text: String, context: ReadingContext) -> (reading: CellReading, step: SeparatorStep?)
    {
        let normalized = normalize(text)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (.text, nil) }
        if trimmed.count == 1, let dash = trimmed.first, dashes.contains(dash) {
            guard context.inTable, context.columnHoldsAmounts else { return (.text, nil) }
            return (.amount(Amount(value: 0, unit: .number, scale: 0, notes: [.dashAsZero])), nil)
        }
        var found: [Token] = []
        for token in tokens(in: normalized) where found.last.map({ token.numberStart >= $0.spanEnd }) ?? true {
            found.append(token)
        }
        guard found.count == 1, let token = found.first else { return (.text, nil) }
        return amount(token, in: normalized, context: context)
    }

    /// The region's convention: the vote of b2 §3.4 steps 3 to 6 over its items.
    public static func convention(of texts: [ColumnText]) -> NumberConvention {
        var decimals: [Character: Int] = [:]
        var groupings: [Character: Int] = [:]
        var symbols: [String: Int] = [:]
        var after = 0
        var before = 0
        var minuses: [Character: Int] = [:]
        var currencySpacings: [String: Int] = [:]
        var percentSpacings: [String: Int] = [:]
        for item in texts {
            let normalized = normalize(item.text)
            for token in tokens(in: normalized) {
                let verdict = shape(token.number)
                if let decimal = vote(verdict) { decimals[decimal, default: 0] += 1 }
                if let grouping = verdict.grouping { groupings[grouping, default: 0] += 1 }
                if let sign = token.sign, minusSigns.contains(sign) { minuses[sign, default: 0] += 1 }
                if let mark = token.suffix.currencyMark {
                    symbols[mark, default: 0] += 1
                    after += 1
                    currencySpacings[token.suffix.currencySpacing.map(String.init) ?? "", default: 0] += 1
                } else if let mark = token.currencyBefore {
                    symbols[mark, default: 0] += 1
                    before += 1
                }
                if token.suffix.percent {
                    percentSpacings[token.suffix.percentSpacing.map(String.init) ?? "", default: 0] += 1
                }
            }
        }
        let symbol = majority(symbols)
        var decimal = majority(decimals)
        if decimal == nil, let symbol {
            decimal = symbol == "€" || Currency.named(symbol) == .eur ? "," : "."
        }
        let decimalSeparator = decimal ?? "."
        var grouping = majority(groupings)
        if grouping == decimalSeparator { grouping = nil }
        return NumberConvention(
            decimalSeparator: decimalSeparator, groupingSeparator: grouping, currencySymbol: symbol,
            symbolAfter: after > before, minus: majority(minuses) ?? "-",
            currencySpacing: majority(currencySpacings)?.first, percentSpacing: majority(percentSpacings)?.first)
    }

    /// The decimal separator most unambiguous numbers in these texts use: a column's verdict (step 3), or the region's
    /// (step 4). `1,234,567` votes too: its `,` groups, so the decimal is the point.
    public static func decimalVote(_ texts: [String]) -> Character? {
        var decimals: [Character: Int] = [:]
        for text in texts {
            for token in tokens(in: normalize(text)) {
                if let decimal = vote(shape(token.number)) { decimals[decimal, default: 0] += 1 }
            }
        }
        return majority(decimals)
    }

    /// The decimal separator one unambiguous number shows: its decimal, or the other mark when `,` or `.` groups it.
    /// `convention(of:)` and `decimalVote` count the same votes, so the region decides with the separator that voted.
    static func vote(_ verdict: Shape) -> Character? {
        if let decimal = verdict.decimal { return decimal }
        switch verdict.grouping {
        case ","?: return "."
        case "."?: return ","
        default: return nil
        }
    }

    /// The key most votes went to; a tie keeps none.
    static func majority<Key: Hashable>(_ votes: [Key: Int]) -> Key? {
        guard let top = votes.values.max() else { return nil }
        let winners = votes.filter { $0.value == top }
        return winners.count == 1 ? winners.first?.key : nil
    }

    /// Fullwidth digits as ASCII, one character for one, so offsets hold in the original text.
    static func normalize(_ text: String) -> String {
        String(
            text.map { character -> Character in
                guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
                    (0xFF10...0xFF19).contains(scalar.value),
                    let ascii = Unicode.Scalar(scalar.value - 0xFF10 + 0x30)
                else { return character }
                return Character(ascii)
            })
    }
}

// MARK: - Scanning: harness.amount_spans, frozen in M13.0

extension DisplayedNumber {
    /// One amount found in a text, in character offsets of the normalized text.
    struct Token {
        var start: Int
        /// Past the unit suffix, as `harness.amount_spans` ends a span.
        var spanEnd: Int
        var numberStart: Int
        var numberEnd: Int
        var number: String
        var sign: Character?
        var currencyBefore: String?
        var parenthesis: Bool
        var suffix: Suffix
    }

    /// What follows the digits.
    struct Suffix {
        var end: Int
        var currencyMark: String?
        var currencySpacing: Character?
        var percent = false
        var percentSpacing: Character?
        var hours: Decimal?
        var scale: Decimal?
        /// `p`, `c`, `¢`, `ct`: a hundredth of the currency.
        var minor: Currency?
        var unitTag = false
        var perUnit = false
        var closesParenthesis = false
        var trailingMinus = false
        /// Letters glued to the digits that no rule reads.
        var glued = false
    }

    nonisolated(unsafe) static let numberPattern =
        #/(?<sign>[\-−–‒﹣－+])?\s*(?<pre>CA\$|C\$|AU\$|A\$|US\$|[€$£¥]|EUR|USD|GBP|CHF)?\s*(?<late>[\-−–‒﹣－+])?\s*(?<paren>\()?\s*(?<inner>[€$£¥]|CHF)?\s*(?<num>\d{1,3}(?:[ \u{00A0}\u{202F}\u{2009}\u{2007}\u{2008}\u{200A}.,'’]\d{3})+(?:[.,]\d+)?(?!\d)|\d+(?:[.,]\d+)?)/#

    nonisolated(unsafe) static let notAmountPattern =
        #/\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}(?:/\d{2,4})?|\d{1,2}\.\d{1,2}\.\d{2,4}|\d{1,2}:\d{2}(?::\d{2})?(?:\s?[AaPp][Mm])?|\d{1,2}\s?[–-]\s?\d{1,2}\s?[ap]m|\b\d{1,2}\s+(?:jan|feb|f[ée]v|mar|apr|avr|may|mai|jun|juin|jul|juil|aug|ao[ûu]|sep|oct|nov|dec|d[ée]c)[a-zéû]*\.?|\b(?:jan|feb|f[ée]v|mar|apr|avr|may|mai|jun|juin|jul|juil|aug|ao[ûu]|sep|oct|nov|dec|d[ée]c)[a-zéû]*\.?\s+\d{1,2}\b|\b[A-Za-z0-9]+(?:[-–][A-Za-z0-9]+)+\b|\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){2,7}(?:\s?[A-Z0-9]{1,4})?\b|\b\d{4}(?:\s\d{4}){2,}\b|\b\d+[×x]\d+\b/#
        .ignoresCase().wordBoundaryKind(.simple)

    nonisolated(unsafe) static let datedPattern =
        #/\b(?:jan|feb|f[ée]v|mar|apr|avr|may|mai|jun|juin|jul|juil|aug|ao[ûu]|sep|oct|nov|dec|d[ée]c)[a-zéû]*\.?(?![a-z])|\b(?:Q|T|H|S)[1-4]\b|\bFY/#
        .ignoresCase().wordBoundaryKind(.simple)

    nonisolated(unsafe) static let suffixPattern =
        #/\s?(?:€|EUR\b|USD\b|GBP\b|CHF\b|%|p\b|[kK]\b|h(?:\s?\d{2})?\b|\)|(?:kg|g|mg|l|L|ml|cl|kWh|Wh|kW|km|m|cm|mm)\b)/#
        .wordBoundaryKind(.simple)

    nonisolated(unsafe) static let ordinalPattern = #/(?:er|e|ème|st|nd|rd|th)\b/#.wordBoundaryKind(.simple)
    nonisolated(unsafe) static let yearPattern = #/(?:19|20)\d\d/#

    static func offset(_ index: String.Index, in text: String) -> Int {
        text.distance(from: text.startIndex, to: index)
    }

    static func index(_ offset: Int, in text: String) -> String.Index {
        text.index(text.startIndex, offsetBy: offset)
    }

    /// The amounts of a normalized text, b2 §3.2's non-amounts left out.
    static func tokens(in text: String) -> [Token] {
        var blankCharacters = Array(text)
        for match in text.matches(of: notAmountPattern) {
            let lower = offset(match.range.lowerBound, in: text)
            let upper = offset(match.range.upperBound, in: text)
            for position in lower..<upper { blankCharacters[position] = " " }
        }
        let blank = String(blankCharacters)
        let dated = blank != text || text.firstMatch(of: datedPattern) != nil
        var found: [Token] = []
        for match in blank.matches(of: numberPattern) {
            let numberStart = offset(match.output.num.startIndex, in: blank)
            let numberEnd = offset(match.output.num.endIndex, in: blank)
            if numberStart > 0 {
                let before = blankCharacters[numberStart - 1]
                if before.isLetter || "#°№".contains(before) { continue }
            }
            if blank[index(numberEnd, in: blank)...].prefixMatch(of: ordinalPattern) != nil { continue }
            let number = String(match.output.num)
            if dated, number.wholeMatch(of: yearPattern) != nil { continue }
            let rest = text[index(numberEnd, in: text)...]
            let spanEnd = rest.prefixMatch(of: suffixPattern).map { offset($0.range.upperBound, in: text) } ?? numberEnd
            let start = offset(match.range.lowerBound, in: blank)
            let pre = match.output.pre ?? match.output.inner
            // A plus then a minus (`+€-12`, `+ -3`) is negative: the minus wins.
            let signs = [match.output.sign, match.output.late].compactMap { $0?.first }
            var token = Token(
                start: start, spanEnd: spanEnd, numberStart: numberStart, numberEnd: numberEnd, number: number,
                sign: signs.first { minusSigns.contains($0) } ?? signs.first, currencyBefore: pre.map(String.init),
                parenthesis: match.output.paren != nil, suffix: Suffix(end: numberEnd))
            token.suffix = suffix(of: token, in: Array(text))
            found.append(token)
        }
        return found
    }
}

// MARK: - What follows the digits (b2 §3.6)

extension DisplayedNumber {
    static let unitTags: Set<String> = [
        "kg", "g", "mg", "l", "L", "ml", "cl", "kWh", "Wh", "kW", "km", "m", "cm", "mm", "x",
    ]
    static let currencySigns: Set<Character> = ["€", "$", "£", "¥", "₩", "₹"]

    static func letters(_ characters: [Character], from start: Int) -> String {
        var end = start
        while end < characters.count, characters[end].isLetter { end += 1 }
        return start < characters.count ? String(characters[start..<end]) : ""
    }

    /// A currency mark at `start`: a sign, or an ISO code standing alone.
    static func currencyMark(_ characters: [Character], at start: Int) -> String? {
        guard start < characters.count else { return nil }
        if currencySigns.contains(characters[start]) { return String(characters[start]) }
        let word = letters(characters, from: start)
        if word.count == 3, word == word.uppercased(), Currency.code(word) != nil { return word }
        return nil
    }

    static func suffix(of token: Token, in characters: [Character]) -> Suffix {
        let count = characters.count
        var result = Suffix(end: token.numberEnd)
        var position = token.numberEnd
        var spacing: Character?
        if position < count, spaceLike.contains(characters[position]) {
            spacing = characters[position]
            position += 1
        }
        let digitsOnly = token.number.allSatisfy(\.isNumber)
        // Hours: 7h30, 7 h 30, 7h, 4.5 h.
        if position < count, characters[position] == "h",
            position + 1 == count || !characters[position + 1].isLetter
        {
            var end = position + 1
            var minutes: Decimal?
            var cursor = end
            if cursor < count, spaceLike.contains(characters[cursor]) { cursor += 1 }
            if digitsOnly, cursor + 1 < count, characters[cursor].isASCII, characters[cursor].isNumber,
                characters[cursor + 1].isASCII, characters[cursor + 1].isNumber,
                cursor + 2 == count || !(characters[cursor + 2].isLetter || characters[cursor + 2].isNumber),
                let tens = characters[cursor].wholeNumberValue, let units = characters[cursor + 1].wholeNumberValue
            {
                minutes = Decimal(tens * 10 + units)
                end = cursor + 2
            }
            if end == position + 1 || minutes != nil {
                result.hours = minutes.map { $0 / 60 } ?? 0
                result.end = end
                result.glued = end < count && characters[end].isLetter
                return result
            }
        }
        var consumed = false
        let word = letters(characters, from: position)
        let currencyFollows = { (at: Int) -> Bool in
            var cursor = at
            if cursor < count, spaceLike.contains(characters[cursor]) { cursor += 1 }
            return currencyMark(characters, at: cursor) != nil
        }
        switch word {
        case "k", "K":
            result.scale = 1000
        case "bn", "Md", "Mrd":
            result.scale = Decimal(sign: .plus, exponent: 9, significand: 1)
        case "M":
            result.scale = Decimal(sign: .plus, exponent: 6, significand: 1)
        case "m" where token.currencyBefore != nil || currencyFollows(position + 1):
            result.scale = Decimal(sign: .plus, exponent: 6, significand: 1)
        default:
            break
        }
        if result.scale != nil {
            position += word.count
            consumed = true
            if position < count, spaceLike.contains(characters[position]) { position += 1 }
        }
        if let mark = currencyMark(characters, at: position) {
            result.currencyMark = mark
            result.currencySpacing = result.scale == nil ? spacing : nil
            position += mark.count
            consumed = true
        } else if token.currencyBefore == nil, result.scale == nil {
            let unit = letters(characters, from: position)
            if unit == "p" {
                result.minor = .gbp
            } else if unit == "c" || (position < count && characters[position] == "¢") {
                result.minor = .usd
            } else if unit == "ct" {
                result.minor = .eur
            }
            if result.minor != nil {
                position += max(unit.count, 1)
                consumed = true
            }
        }
        if result.currencyMark == nil, result.minor == nil, result.scale == nil {
            if position < count, characters[position] == "%" {
                result.percent = true
                result.percentSpacing = spacing
                position += 1
                consumed = true
            } else if unitTags.contains(word) || (position < count && characters[position] == "×") {
                result.unitTag = true
                position += max(word.count, 1)
                consumed = true
            }
        }
        // A price per unit, `€/L` or `€ / L`.
        if result.currencyMark != nil || token.currencyBefore != nil {
            var slash = position
            while slash < count, spaceLike.contains(characters[slash]) { slash += 1 }
            var unit = slash + 1
            while unit < count, spaceLike.contains(characters[unit]) { unit += 1 }
            if slash < count, characters[slash] == "/", unit < count, characters[unit].isLetter {
                result.perUnit = true
                position = unit + letters(characters, from: unit).count
            }
        }
        if token.parenthesis {
            var cursor = position
            while cursor < count, spaceLike.contains(characters[cursor]) { cursor += 1 }
            if let mark = currencyMark(characters, at: cursor), result.currencyMark == nil {
                result.currencyMark = mark
                cursor += mark.count
                while cursor < count, spaceLike.contains(characters[cursor]) { cursor += 1 }
            }
            if cursor < count, characters[cursor] == ")" {
                result.closesParenthesis = true
                position = cursor + 1
            }
        }
        if position < count, minusSigns.contains(characters[position]),
            characters[(position + 1)...].allSatisfy(\.isWhitespace)
        {
            result.trailingMinus = true
        }
        let gluedAt = consumed && spacing == nil ? position : token.numberEnd
        result.glued = gluedAt < count && characters[gluedAt].isLetter && (gluedAt == token.numberEnd || consumed)
        result.end = position
        return result
    }
}

// MARK: - Separators (b2 §3.4) and the Decimal (b2 §3.7)

extension DisplayedNumber {
    /// What the token alone says about its marks.
    struct Shape {
        var integer: String
        var fraction: String
        var decimal: Character?
        var grouping: Character?
        /// One `.` or `,` before exactly three digits after a lead of one to three: steps 2 to 6 decide.
        var ambiguous: Character?
        var invalid = false
    }

    static func shape(_ number: String) -> Shape {
        var runs: [String] = [""]
        var marks: [Character] = []
        for character in number {
            if character.isNumber {
                runs[runs.count - 1].append(character)
            } else {
                marks.append(character)
                runs.append("")
            }
        }
        guard let lead = runs.first, let last = runs.last, let lastMark = marks.last else {
            return Shape(integer: number, fraction: "")
        }
        let groupsValid = { (groups: ArraySlice<String>, marks: ArraySlice<Character>) -> Bool in
            lead.count <= 3 && groups.allSatisfy { $0.count == 3 } && Set(marks).count <= 1
        }
        let decimalMark = lastMark == "." || lastMark == ","
        if last.count != 3 || (marks.count == 1 && (lead.count > 3 || lead == "0")) {
            guard decimalMark else { return Shape(integer: "", fraction: "", invalid: true) }
            let groupMarks = marks.dropLast()
            guard groupMarks.allSatisfy({ $0 != lastMark }),
                groupMarks.isEmpty || groupsValid(runs.dropFirst().dropLast(), groupMarks)
            else { return Shape(integer: "", fraction: "", invalid: true) }
            return Shape(
                integer: runs.dropLast().joined(), fraction: last, decimal: lastMark, grouping: groupMarks.first)
        }
        let uniform = Set(marks).count == 1
        if uniform {
            guard groupsValid(runs.dropFirst()[...], marks[...]) else {
                return Shape(integer: "", fraction: "", invalid: true)
            }
            if !decimalMark || marks.count >= 2 {
                return Shape(integer: runs.joined(), fraction: "", grouping: lastMark)
            }
            return Shape(integer: runs.joined(), fraction: "", ambiguous: lastMark)
        }
        let groupMarks = marks.dropLast()
        guard decimalMark, groupMarks.allSatisfy({ $0 != lastMark }),
            groupsValid(runs.dropFirst().dropLast(), groupMarks)
        else { return Shape(integer: "", fraction: "", invalid: true) }
        return Shape(integer: runs.dropLast().joined(), fraction: last, decimal: lastMark, grouping: groupMarks.first)
    }

    /// Exact and locale-free: the digits are the significand, the fraction length the exponent. Nil past 38 digits.
    static func decimal(integer: String, fraction: String, negative: Bool) -> Decimal? {
        let digits = (integer + fraction).drop { $0 == "0" }
        guard digits.count <= maxDigits else { return nil }
        var significand = Decimal(0)
        for character in integer + fraction {
            guard let digit = character.wholeNumberValue else { return nil }
            significand = significand * 10 + Decimal(digit)
        }
        if significand == 0 { return 0 }
        return Decimal(sign: negative ? .minus : .plus, exponent: -fraction.count, significand: significand)
    }

    /// The currency a mark names, with the region's say on a bare `$` or `¥`.
    static func currency(_ mark: String, region: Currency?) -> Currency? {
        if mark == "$", let region, region.symbols.contains(where: { $0.hasSuffix("$") }) { return region }
        if mark == "¥", region?.code == "CNY" { return region }
        return Currency.named(mark)
    }

    static func amount(_ token: Token, in text: String, context: ReadingContext) -> (CellReading, SeparatorStep?) {
        let suffix = token.suffix
        let mark = token.currencyBefore ?? suffix.currencyMark
        let named = mark.flatMap { currency($0, region: context.currency) }
        if mark != nil, named == nil { return (.text, nil) }
        var notes: Set<AmountNote> = []
        let shape = shape(token.number)
        if shape.invalid { return (.text, nil) }
        var integer = shape.integer
        var fraction = shape.fraction
        var step: SeparatorStep? = shape.decimal != nil || shape.grouping != nil ? .token : nil
        if let ambiguous = shape.ambiguous {
            let (isDecimal, decided) = decide(ambiguous, currency: named, perUnit: suffix.perUnit, context: context)
            step = decided
            if decided == .currency || decided == .macLocale { notes.insert(.assumedConvention) }
            if isDecimal {
                let parts = token.number.split(separator: ambiguous)
                integer = String(parts.first ?? "")
                fraction = String(parts.last ?? "")
            }
        }
        if suffix.glued {
            // Complete for the currency (its minor units, behind its usual mark) or, with none, for the region.
            let complete: Bool
            if let currency = named ?? context.currency {
                let usual: Character = currency == .eur ? "," : "."
                complete = fraction.count == currency.minorUnits && shape.decimal == usual
            } else {
                complete =
                    fraction.count == 2 && shape.decimal != nil && shape.decimal == context.region?.decimalSeparator
            }
            guard complete, suffix.hours == nil else { return (.garbled, step) }
            notes.insert(.doubt)
        }
        let parenthesized = token.parenthesis && suffix.closesParenthesis
        var negative = token.sign.map { minusSigns.contains($0) } ?? false
        if suffix.trailingMinus, context.inTable { negative = true }
        if parenthesized {
            notes.insert(.parenthesized)
            if !fraction.isEmpty || named != nil || context.columnSigned { negative = true }
        }
        guard var value = decimal(integer: integer, fraction: fraction, negative: negative) else {
            return (.text, step)
        }
        var scale = fraction.count
        var unit: CellUnit = named.map { .money($0) } ?? .number
        if let hours = suffix.hours {
            value += negative ? -hours : hours
            unit = .hours
        } else if suffix.percent {
            unit = .percent
        } else if let minor = suffix.minor {
            value /= 100
            scale += 2
            unit = .money(minor == .gbp ? minor : (context.currency ?? minor))
            notes.insert(.pence)
        }
        if let factor = suffix.scale {
            value *= factor
            notes.insert(.approximate)
        }
        let before = String(text[index(0, in: text)..<index(token.numberStart, in: text)]).lowercased()
        if before.contains("~") || before.contains("≈") || before.hasSuffix("ca. ") || before.hasSuffix("about ")
            || before.hasSuffix("env. ") || before.hasSuffix("environ ")
        {
            notes.insert(.approximate)
        }
        return (.amount(Amount(value: value, unit: unit, scale: scale, notes: notes)), step)
    }

    /// Steps 2 to 6 for one ambiguous mark: whether it is the decimal, and the step that said so.
    static func decide(
        _ mark: Character, currency: Currency?, perUnit: Bool, context: ReadingContext
    ) -> (Bool, SeparatorStep) {
        if let currency, !perUnit, currency.minorUnits < 3 { return (false, .currencyMinorUnits) }
        if let column = context.columnDecimal { return (column == mark, .column) }
        if let region = context.region { return (region.decimalSeparator == mark, .region) }
        if let named = currency ?? context.currency { return ((named == .eur ? "," : ".") == mark, .currency) }
        return (context.macDecimal == mark, .macLocale)
    }
}
