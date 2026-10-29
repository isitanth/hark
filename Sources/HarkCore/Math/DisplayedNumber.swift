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

/// Reads the numbers a document displays, in its own separators: never a locale literal, never binary floating point.
public enum DisplayedNumber {
    /// The amounts in one item's text, in order: what the sheet builder splits on (one ID, one number).
    public static func amounts(in text: String) -> [Range<String.Index>] {
        []
    }

    /// One item, read in its context.
    public static func read(_ text: String, context: ReadingContext) -> CellReading {
        .garbled
    }

    /// The region's convention: the vote of b2 §3.4 steps 3 to 6 over its items.
    public static func convention(of texts: [ColumnText]) -> NumberConvention {
        .plain
    }
}
