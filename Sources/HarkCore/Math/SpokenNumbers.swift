import Foundation

// The constants a formula may hold (M13, b2 §6): `harness.spoken_numbers` and `allowed_constants`, frozen in M13.0.

public enum SpokenNumbers {
    /// b2 §6's closed table: a percent, grams in a kilo, months, weeks, days, hours, minutes and seconds.
    public static let conversions: Set<Decimal> = [100, 1000, 12, 52, 7, 24, 60, 365, 3600]

    static let english: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100, "thousand": 1000, "dozen": 12,
        "double": 2, "twice": 2, "triple": 3, "third": 3, "quarter": 4,
    ]
    static let french: [String: Int] = [
        "zéro": 0, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "sept": 7, "huit": 8,
        "neuf": 9, "dix": 10, "onze": 11, "douze": 12, "treize": 13, "quatorze": 14, "quinze": 15, "seize": 16,
        "vingt": 20, "vingts": 20, "trente": 30, "quarante": 40, "cinquante": 50, "soixante": 60, "cent": 100,
        "cents": 100, "mille": 1000, "double": 2, "triple": 3, "tiers": 3, "quart": 4,
    ]
    static let halves: [String: [Decimal]] = [
        "half": [2, Decimal(sign: .plus, exponent: -1, significand: 5)],
        "moitié": [2, Decimal(sign: .plus, exponent: -1, significand: 5)],
        "demi": [2, Decimal(sign: .plus, exponent: -1, significand: 5)],
        "quarter": [4, Decimal(sign: .plus, exponent: -2, significand: 25)],
        "quart": [4, Decimal(sign: .plus, exponent: -2, significand: 25)],
    ]

    nonisolated(unsafe) static let wordPattern = #/[a-zà-ÿ]+(?:(?:-| et )[a-zà-ÿ]+)*/#

    /// The numbers the user said, in digits or in English or French words, each with its percent forms, plus the
    /// closed table of conversions, 0 and 1.
    public static func allowed(in instruction: String) -> Set<Decimal> {
        var allowed: Set<Decimal> = conversions.union([0, 1])
        for number in spoken(in: instruction) {
            allowed.formUnion([number, number / 100, 1 + number / 100, 1 - number / 100])
        }
        return allowed
    }

    /// The numbers themselves, before their derivations.
    public static func spoken(in instruction: String) -> Set<Decimal> {
        var numbers: Set<Decimal> = []
        for range in DisplayedNumber.amounts(in: instruction) {
            if case .amount(let amount) = DisplayedNumber.read(String(instruction[range]), context: ReadingContext()) {
                numbers.insert(amount.value < 0 ? -amount.value : amount.value)
            }
        }
        let lowered = instruction.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        for match in lowered.matches(of: wordPattern) {
            let parts = match.output.split(whereSeparator: { $0 == "-" || $0 == " " }).map(String.init)
            for table in [english, french] {
                if let value = compound(parts, table) { numbers.insert(Decimal(value)) }
                for part in parts {
                    if let value = table[part] { numbers.insert(Decimal(value)) }
                    if let values = halves[part] { numbers.formUnion(values) }
                }
            }
        }
        return numbers
    }

    /// A hyphenated or `et`-joined compound: twenty-five, vingt-cinq, soixante et onze, quatre-vingt-dix.
    static func compound(_ words: [String], _ table: [String: Int]) -> Int? {
        var total = 0
        var current = 0
        for word in words where word != "et" {
            guard let value = table[word] else { return nil }
            if value == 100 {
                current = (current == 0 ? 1 : current) * 100
            } else if value == 1000 {
                total += (current == 0 ? 1 : current) * 1000
                current = 0
            } else if (word == "vingt" || word == "vingts") && current == 4 {
                current = 80
            } else {
                current += value
            }
        }
        return total + current
    }
}
