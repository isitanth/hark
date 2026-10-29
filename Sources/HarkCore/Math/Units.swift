import Foundation

// Units and currencies (M13, b2 §4). S1 implements this.

/// A currency the number parser knows: its ISO code, its minor units and the symbols that name it.
public struct Currency: Hashable, Sendable {
    public let code: String
    public let minorUnits: Int
    public let symbols: [String]

    public init(code: String, minorUnits: Int, symbols: [String]) {
        self.code = code
        self.minorUnits = minorUnits
        self.symbols = symbols
    }

    /// The hard-coded table (b2 §4.5). No conversion, ever.
    public static let table: [Currency] = []
}

/// A cell's unit, as its text shows it.
public enum CellUnit: Hashable, Sendable {
    case money(Currency)
    case percent
    case hours
    case number
}

/// A computed value's unit, from the unit algebra (b2 §4.3).
public enum MathUnit: Hashable, Sendable {
    case money(Currency)
    case percent
    case count
    case hours
    case number
}
