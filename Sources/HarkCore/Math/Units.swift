import Foundation

// Units and currencies (M13, b2 §4).

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

    public static let eur = Currency(code: "EUR", minorUnits: 2, symbols: ["€"])
    public static let usd = Currency(code: "USD", minorUnits: 2, symbols: ["$", "US$"])
    public static let gbp = Currency(code: "GBP", minorUnits: 2, symbols: ["£"])
    public static let chf = Currency(code: "CHF", minorUnits: 2, symbols: ["Fr."])
    public static let cad = Currency(code: "CAD", minorUnits: 2, symbols: ["CA$", "C$"])
    public static let aud = Currency(code: "AUD", minorUnits: 2, symbols: ["A$", "AU$"])
    public static let jpy = Currency(code: "JPY", minorUnits: 0, symbols: ["¥", "円"])

    /// The hard-coded table (b2 §4.5), so rounding does not move with ICU. No conversion, ever.
    public static let table: [Currency] = [
        eur, usd, gbp, chf, cad, aud, jpy,
        Currency(code: "BHD", minorUnits: 3, symbols: []),
        Currency(code: "KWD", minorUnits: 3, symbols: []),
        Currency(code: "TND", minorUnits: 3, symbols: []),
        Currency(code: "KRW", minorUnits: 0, symbols: ["₩"]),
        Currency(code: "CLF", minorUnits: 4, symbols: []),
        Currency(code: "CNY", minorUnits: 2, symbols: ["元", "RMB"]),
        Currency(code: "SEK", minorUnits: 2, symbols: []),
        Currency(code: "NOK", minorUnits: 2, symbols: []),
        Currency(code: "DKK", minorUnits: 2, symbols: []),
        Currency(code: "PLN", minorUnits: 2, symbols: []),
        Currency(code: "CZK", minorUnits: 2, symbols: []),
        Currency(code: "NZD", minorUnits: 2, symbols: []),
        Currency(code: "SGD", minorUnits: 2, symbols: []),
        Currency(code: "HKD", minorUnits: 2, symbols: []),
        Currency(code: "INR", minorUnits: 2, symbols: ["₹"]),
        Currency(code: "BRL", minorUnits: 2, symbols: ["R$"]),
        Currency(code: "MXN", minorUnits: 2, symbols: []),
        Currency(code: "ZAR", minorUnits: 2, symbols: []),
    ]

    /// The currency an ISO code names, from the table only.
    public static func code(_ code: String) -> Currency? {
        table.first { $0.code == code.uppercased() }
    }

    /// The currency a symbol or code names. `$` alone is USD and `¥` JPY: the region may say otherwise (b2 §4.5).
    public static func named(_ mark: String) -> Currency? {
        if let byCode = code(mark), mark.count == 3, mark == mark.uppercased() { return byCode }
        return table.first { $0.symbols.contains(mark) }
    }

    /// How the working line writes it: its first symbol, else its code.
    public var displaySymbol: String { symbols.first ?? code }
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

    init(_ unit: CellUnit) {
        switch unit {
        case .money(let currency): self = .money(currency)
        case .percent: self = .percent
        case .hours: self = .hours
        case .number: self = .number
        }
    }

    /// How a retry note names it: words, never Hark's notation.
    var words: String {
        switch self {
        case .money(let currency): "an amount in \(currency.code)"
        case .percent: "a percent"
        case .count: "a count"
        case .hours: "hours"
        case .number: "a plain number"
        }
    }
}
