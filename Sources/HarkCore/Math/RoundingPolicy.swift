import Foundation

// Rounding, once, at display (M13, b2 §8; decision 19: a code constant). S1 owns this file after the contract.

/// How a computed value is rounded for display: money to its currency's minor units, percent and hours to two
/// decimals, a count exactly. The value itself stays exact.
public struct RoundingPolicy: Sendable, Equatable {
    public enum Rule: String, Sendable, CaseIterable {
        case halfUp = "half_up"
        case halfEven = "half_even"
        case down
    }

    public var rule: Rule
    public var percentDecimals: Int
    public var hoursDecimals: Int
    public var numberDecimals: Int

    public init(rule: Rule = .halfUp, percentDecimals: Int = 2, hoursDecimals: Int = 2, numberDecimals: Int = 2) {
        self.rule = rule
        self.percentDecimals = percentDecimals
        self.hoursDecimals = hoursDecimals
        self.numberDecimals = numberDecimals
    }

    public static let standard = RoundingPolicy()
}

extension RoundingPolicy {
    /// The division residue goes first: 38 digits of a third would round differently from the value meant.
    static let snapScale = 20

    /// `value` to `scale` decimals by `rule`; half up is half away from zero, the cases' `ROUND_HALF_UP`.
    public static func round(_ value: Decimal, scale: Int, rule: Rule) -> Decimal {
        var input = value
        var output = Decimal()
        let mode: NSDecimalNumber.RoundingMode =
            switch rule {
            case .halfUp: .plain
            case .halfEven: .bankers
            case .down: .down
            }
        NSDecimalRound(&output, &input, scale, mode)
        return output
    }

    /// The unit the answer shows: a plain number takes the declared unit, and a non-integer count is a number.
    public static func displayUnit(_ unit: MathUnit, declared: ResultUnit, value: Decimal) -> MathUnit {
        switch (unit, declared) {
        case (.number, .eur): return .money(.eur)
        case (.number, .usd): return .money(.usd)
        case (.number, .gbp): return .money(.gbp)
        case (.number, .percent): return .percent
        case (.number, .hours): return .hours
        case (.number, .count), (.count, _):
            return round(value, scale: 0, rule: .down) == value ? .count : .number
        default: return unit
        }
    }

    /// The decimals a value shows: rounded to `maximum`, trailing zeros trimmed down to `minimum`. Nil: exact.
    public func decimals(for unit: MathUnit, read: [CellID], sheet: CellSheet) -> (maximum: Int, minimum: Int)? {
        switch unit {
        case .money(let currency): return (currency.minorUnits, currency.minorUnits)
        case .percent: return (percentDecimals, percentDecimals)
        case .hours: return (hoursDecimals, hoursDecimals)
        case .count: return nil
        case .number:
            let scales = read.compactMap { id -> Int? in
                guard case .amount(let amount) = sheet[id]?.reading else { return nil }
                return amount.scale
            }
            let most = scales.max() ?? 0
            return (max(most, numberDecimals), most)
        }
    }

    /// Snapped to 20 places, then rounded once by the policy. A count stays exact.
    public func round(_ value: Decimal, unit: MathUnit, read: [CellID], sheet: CellSheet) -> Decimal {
        let snapped = Self.round(value, scale: Self.snapScale, rule: .halfUp)
        guard let decimals = decimals(for: unit, read: read, sheet: sheet) else { return snapped }
        return Self.round(snapped, scale: decimals.maximum, rule: rule)
    }
}
