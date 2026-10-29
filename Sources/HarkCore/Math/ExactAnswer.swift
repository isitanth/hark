import Foundation

// The answer Hark writes itself (M13, b2 §10). S1 implements this.

/// A figure the `understood` line names, and where it came from: decision 17's check line.
public struct UnderstoodFigure: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// A cell the formula read.
        case cell(CellID)
        /// The user's words.
        case spoken
        /// Neither: the panel says it is not on screen.
        case nowhere
    }

    public let text: String
    public let source: Source

    public init(text: String, source: Source) {
        self.text = text
        self.source = source
    }
}

/// The exact answer: the model's restatement, the working in the document's format, and the result in the user's.
/// The model's text never carries the number.
public struct ExactAnswer: Sendable, Equatable {
    /// Nil only when the plan's `understood` is empty.
    public let understood: String?
    /// The working, built from the formula, with no words.
    public let working: String?
    public let result: String
    /// The unrounded value, when rounding changed it.
    public let exact: String?
    public let figures: [UnderstoodFigure]

    /// `fallback` is the user's format for the result (decision 8): the system's Language & Region format, passed in.
    public init(_ computation: Computation, sheet: CellSheet, policy: RoundingPolicy, fallback: Locale) {
        let plan = computation.plan
        understood = plan.understood.isEmpty ? nil : plan.understood
        let unit = RoundingPolicy.displayUnit(computation.unit, declared: plan.unit, value: computation.value)
        let decimals = policy.decimals(for: unit, read: computation.read, sheet: sheet)
        let shown = policy.round(computation.value, unit: unit, read: computation.read, sheet: sheet)
        let snapped = RoundingPolicy.round(computation.value, scale: RoundingPolicy.snapScale, rule: .halfUp)
        let value = ResultFormat.string(shown, unit: unit, decimals: decimals, locale: fallback)
        if let winner = computation.winner, let label = sheet[winner.label] {
            result = label.text.split(whereSeparator: \.isNewline).joined(separator: " ") + " — " + value
        } else {
            result = value
        }
        exact =
            shown == snapped
            ? nil
            : ResultFormat.string(
                snapped, unit: unit, decimals: (RoundingPolicy.snapScale, decimals?.minimum ?? 0), locale: fallback)
        working = WorkingLine(sheet: sheet).line(computation.formula)
        figures = understood.map { UnderstoodFigures.figures(in: $0, computation: computation, sheet: sheet) } ?? []
    }

    /// The reply as a turn of the conversation keeps it: the `%%` line, then the working, then the result alone.
    public var reply: String {
        let body = [working, result].compactMap { $0 }.joined(separator: "\n")
        return IntentSplit.marker + " " + (understood ?? "") + "\n\n" + body
    }
}

/// The result in the user's own format: `Decimal.FormatStyle`, for formatting only.
enum ResultFormat {
    static func string(_ value: Decimal, unit: MathUnit, decimals: (maximum: Int, minimum: Int)?, locale: Locale)
        -> String
    {
        let fraction = decimals.map { $0.minimum...max($0.minimum, $0.maximum) } ?? 0...RoundingPolicy.snapScale
        switch unit {
        case .money(let currency):
            let digits = decimals.map { max($0.minimum, currency.minorUnits)...max($0.maximum, currency.minorUnits) }
            return value.formatted(
                Decimal.FormatStyle.Currency(code: currency.code, locale: locale)
                    .precision(.fractionLength(digits ?? currency.minorUnits...currency.minorUnits)))
        case .percent:
            return (value / 100).formatted(
                Decimal.FormatStyle.Percent(locale: locale).precision(.fractionLength(fraction)))
        case .hours:
            return value.formatted(Decimal.FormatStyle(locale: locale).precision(.fractionLength(fraction)))
                + "\u{00A0}h"
        case .count, .number:
            return value.formatted(Decimal.FormatStyle(locale: locale).precision(.fractionLength(fraction)))
        }
    }
}

/// The working, in the document's own format: its separators, its currency sign on its side with its space, its
/// minus. No words: numbers, operators and signs only.
struct WorkingLine {
    let sheet: CellSheet
    var convention: NumberConvention { sheet.convention }
    static let maxTerms = 12

    func line(_ formula: Formula) -> String? {
        guard !formula.containsCount, formula.cells.count <= Self.maxTerms else { return nil }
        return render(formula) + " ="
    }

    var separator: String { convention.decimalSeparator == "," ? " ; " : ", " }
    var minus: String { String(convention.minus) }

    func precedence(_ formula: Formula) -> Int {
        switch formula {
        case .binary(.add, _, _), .binary(.subtract, _, _): 1
        case .binary(.multiply, _, _), .binary(.divide, _, _): 2
        case .negate: 3
        default: 4
        }
    }

    func wrapped(_ formula: Formula, below level: Int) -> String {
        precedence(formula) < level ? "(" + render(formula) + ")" : render(formula)
    }

    func render(_ formula: Formula) -> String {
        switch formula {
        case .cell(let id):
            return cell(id, absolute: false)
        case .constant(let value):
            return number(value, scale: Self.scale(of: value), grouping: false)
        case .negate(let inner):
            return minus + wrapped(inner, below: 3)
        case .rate(let inner):
            if case .cell(let id) = inner, case .amount(let amount) = sheet[id]?.reading, amount.unit == .percent {
                return render(inner)
            }
            return wrapped(inner, below: 4) + (convention.percentSpacing.map(String.init) ?? "") + "%"
        case .binary(let operation, let left, let right):
            let level = operation == .add || operation == .subtract ? 1 : 2
            let symbol =
                switch operation {
                case .add: " + "
                case .subtract: " " + minus + " "
                case .multiply: " × "
                case .divide: " / "
                }
            let tight = operation == .subtract || operation == .divide
            return wrapped(left, below: level) + symbol + wrapped(right, below: tight ? level + 1 : level)
        case .call(.sum, let arguments):
            return sum(arguments)
        case .call(.avg, let arguments):
            return "(" + sum(arguments) + ") / \(arguments.count)"
        case .call(.abs, let arguments):
            return "|" + arguments.map(render).joined(separator: separator) + "|"
        case .call(let function, let arguments):
            return function.rawValue + "(" + arguments.map(render).joined(separator: separator) + ")"
        case .round(let inner, let digits):
            return "ROUND(" + render(inner) + separator + "\(digits))"
        case .pick(let pick, let arms):
            return pick.rawValue + "(" + arms.map { render($0.value) }.joined(separator: separator) + ")"
        case .count(let ids):
            return "COUNT(" + ids.map { cell($0, absolute: false) }.joined(separator: separator) + ")"
        }
    }

    /// `a + b − c`: a negative cell folds into a subtraction.
    func sum(_ arguments: [Formula]) -> String {
        var text = ""
        for (index, argument) in arguments.enumerated() {
            if index > 0, case .cell(let id) = argument, case .amount(let amount) = sheet[id]?.reading, amount.value < 0
            {
                text += " " + minus + " " + cell(id, absolute: true)
            } else {
                text += (index == 0 ? "" : " + ") + wrapped(argument, below: 2)
            }
        }
        return text
    }

    func cell(_ id: CellID, absolute: Bool) -> String {
        guard let cell = sheet[id], case .amount(let amount) = cell.reading else { return id.description }
        let negative = amount.value < 0 && !absolute
        let digits = number(amount.value < 0 ? -amount.value : amount.value, scale: amount.scale, grouping: true)
        let sign = negative ? minus : ""
        switch amount.unit {
        case .money(let currency):
            let symbol =
                convention.currencySymbol.flatMap { Currency.named($0) == currency ? $0 : nil }
                ?? currency.displaySymbol
            let space = convention.currencySpacing.map(String.init) ?? ""
            if convention.symbolAfter { return sign + digits + space + symbol }
            return sign + symbol + (symbol.last?.isLetter == true ? " " : "") + digits
        case .percent:
            return sign + digits + (convention.percentSpacing.map(String.init) ?? "") + "%"
        case .hours:
            return sign + digits + "\u{00A0}h"
        case .number:
            return sign + digits
        }
    }

    /// Fixed decimals in the document's separators, built from the Decimal's own digits.
    func number(_ value: Decimal, scale: Int, grouping: Bool) -> String {
        let negative = value < 0
        let magnitude = RoundingPolicy.round(negative ? -value : value, scale: scale, rule: .halfUp)
        var digits = (magnitude * Decimal(sign: .plus, exponent: scale, significand: 1)).description
        while digits.count <= scale { digits = "0" + digits }
        var integer = String(digits.dropLast(scale))
        let fraction = String(digits.suffix(scale))
        if grouping, let group = convention.groupingSeparator, integer.count > 3 {
            var grouped = ""
            for (offset, character) in integer.enumerated() {
                if offset > 0, (integer.count - offset) % 3 == 0 { grouped.append(group) }
                grouped.append(character)
            }
            integer = grouped
        }
        let body = scale > 0 ? integer + String(convention.decimalSeparator) + fraction : integer
        return (negative ? minus : "") + body
    }

    /// The fewest decimals that write the value exactly, up to the snap.
    static func scale(of value: Decimal) -> Int {
        (0...RoundingPolicy.snapScale).first { RoundingPolicy.round(value, scale: $0, rule: .halfUp) == value }
            ?? RoundingPolicy.snapScale
    }
}

extension Formula {
    var containsCount: Bool {
        switch self {
        case .count: true
        case .cell, .constant: false
        case .negate(let inner), .rate(let inner), .round(let inner, _): inner.containsCount
        case .binary(_, let left, let right): left.containsCount || right.containsCount
        case .call(_, let arguments): arguments.contains(where: \.containsCount)
        case .pick(_, let arms): arms.contains { $0.value.containsCount }
        }
    }
}

/// Decision 17: the figures `understood` names, and where each came from. Years and unit-less integers under 1000
/// ("the 6 rows") are not figures.
enum UnderstoodFigures {
    static func figures(in understood: String, computation: Computation, sheet: CellSheet) -> [UnderstoodFigure] {
        DisplayedNumber.amounts(in: understood).compactMap { range -> UnderstoodFigure? in
            let text = understood[range].trimmingCharacters(in: .whitespaces)
            let context = ReadingContext(region: sheet.convention)
            guard case .amount(let amount) = DisplayedNumber.read(text, context: context) else { return nil }
            let value = amount.value < 0 ? -amount.value : amount.value
            let integer = RoundingPolicy.round(value, scale: 0, rule: .down) == value
            if amount.unit == .number, integer, value < 1000 || (1900...2099).contains(value) { return nil }
            if let id = computation.read.first(where: { matches(sheet[$0], value: value, text: text) }) {
                return UnderstoodFigure(text: text, source: .cell(id))
            }
            let spoken = computation.formula.constants.contains { constant in
                [constant, constant * 100, (constant - 1) * 100, (1 - constant) * 100].contains(value)
            }
            return UnderstoodFigure(text: text, source: spoken ? .spoken : .nowhere)
        }
    }

    static func matches(_ cell: Cell?, value: Decimal, text: String) -> Bool {
        guard let cell else { return false }
        if cell.text.contains(text) { return true }
        guard case .amount(let amount) = cell.reading else { return false }
        return amount.value == value || amount.value == -value
    }
}
