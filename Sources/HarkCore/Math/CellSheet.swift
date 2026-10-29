import CoreGraphics
import Foundation

// The reader's output (M13), plain values. S2 owns this file after the contract.

/// A cell's ID in the listing the model gets: `C12` is 12. The model answers with IDs, never with numbers it copied.
public struct CellID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let index: Int

    public init(_ index: Int) {
        self.index = index
    }

    /// `C12` or `c12`: a positive number with no leading zero. Nil for anything else.
    public init?(_ text: String) {
        guard let first = text.first, first == "C" || first == "c" else { return nil }
        let digits = text.dropFirst()
        guard let lead = digits.first, lead != "0", digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
            let index = Int(digits)
        else { return nil }
        self.index = index
    }

    public var description: String { "C\(index)" }

    public static func < (lhs: CellID, rhs: CellID) -> Bool { lhs.index < rhs.index }
}

/// One item the reader found: a table cell, a part of one split by lines or by amounts, or a line outside every
/// table. Never logged, never on disk.
public struct Cell: Sendable, Equatable {
    public let id: CellID
    /// The text as read.
    public let text: String
    /// What the number parser made of the text.
    public let reading: CellReading
    /// Normalized to the region, top-left origin.
    public let box: CGRect
    /// Nil table: a line outside every table.
    public let table: Int?
    public let row: Int?
    public let column: Int?
    /// The reader could not confirm the text: still unread after its last re-read.
    public let suspicious: Bool

    public init(
        id: CellID, text: String, reading: CellReading, box: CGRect, table: Int?, row: Int?, column: Int?,
        suspicious: Bool
    ) {
        self.id = id
        self.text = text
        self.reading = reading
        self.box = box
        self.table = table
        self.row = row
        self.column = column
        self.suspicious = suspicious
    }
}

/// How the region writes its numbers, decided by a vote over its unambiguous cells. The working line is written in
/// it; the result is written in the user's own format.
public struct NumberConvention: Sendable, Equatable {
    public var decimalSeparator: Character
    /// Nil: the region groups no digits.
    public var groupingSeparator: Character?
    public var currencySymbol: String?
    /// `12,50 €` rather than `€12.50`.
    public var symbolAfter: Bool
    /// The minus its negative numbers use: `-`, `−` or `–`.
    public var minus: Character
    /// What goes before a currency symbol written after the number: a space, U+00A0, U+202F, or nil for none.
    public var currencySpacing: Character?
    /// The same before `%`.
    public var percentSpacing: Character?

    public init(
        decimalSeparator: Character, groupingSeparator: Character? = nil, currencySymbol: String? = nil,
        symbolAfter: Bool = false, minus: Character = "-", currencySpacing: Character? = nil,
        percentSpacing: Character? = nil
    ) {
        self.decimalSeparator = decimalSeparator
        self.groupingSeparator = groupingSeparator
        self.currencySymbol = currencySymbol
        self.symbolAfter = symbolAfter
        self.minus = minus
        self.currencySpacing = currencySpacing
        self.percentSpacing = percentSpacing
    }

    /// A point and no grouping: what a region with no unambiguous number gets.
    public static let plain = NumberConvention(decimalSeparator: ".")
}

/// Everything the reader found in one frame. Its description prints counts only, like `SelectionSnapshot`'s.
public struct CellSheet: Sendable, Equatable, CustomStringConvertible {
    public let cells: [Cell]
    public let convention: NumberConvention
    /// The read's duration, cold start included.
    public let readMs: Int

    public init(cells: [Cell], convention: NumberConvention, readMs: Int) {
        self.cells = cells
        self.convention = convention
        self.readMs = readMs
    }

    public subscript(id: CellID) -> Cell? {
        cells.first { $0.id == id }
    }

    /// Whether any cell reads as an amount: a frame with none takes today's path.
    public var hasAmount: Bool {
        cells.contains {
            guard case .amount = $0.reading else { return false }
            return true
        }
    }

    public var description: String {
        let tables = Set(cells.compactMap(\.table)).count
        let suspicious = cells.filter(\.suspicious).count
        return "CellSheet(\(cells.count) cells, \(tables) tables, \(suspicious) suspicious, \(readMs) ms)"
    }
}
