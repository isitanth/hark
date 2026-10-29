import Foundation

// The constants a formula may hold (M13, b2 §6). S1 implements this.

public enum SpokenNumbers {
    /// The numbers the user said, in digits or in English or French words, each with its percent forms, plus the
    /// closed table of conversions.
    public static func allowed(in instruction: String) -> Set<Decimal> {
        []
    }
}
