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
