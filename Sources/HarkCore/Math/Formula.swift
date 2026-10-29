import Foundation

// The formula language (M13, b2 §5). S1 implements this.

/// A formula over cell IDs, as the model writes it in its plan: `SUM(C7, C11) - ABS(C15)`.
public indirect enum Formula: Sendable, Equatable {
    case cell(CellID)
    case constant(Decimal)
    case negate(Formula)
    /// A postfix `%`: the value divided by 100.
    case rate(Formula)
    case binary(BinaryOperator, Formula, Formula)
    /// SUM, AVG, MIN, MAX, ABS.
    case call(FormulaFunction, [Formula])
    /// COUNT takes cells only.
    case count([CellID])
    case round(Formula, digits: Int)
    /// ARGMIN, ARGMAX: the winning arm's value, its label naming the row.
    case pick(Pick, [PickArm])

    /// The formula language of b2 §5.1, by recursive descent: `harness.parse_formula`'s rules and limits.
    public static func parse(_ text: String) -> Result<Formula, PlanDefect> {
        parseKeepingLiterals(text).map(\.formula)
    }

    /// The tree, and its literals as the model wrote them, in the order of `constants`.
    static func parseKeepingLiterals(_ text: String) -> Result<(formula: Formula, literals: [String]), PlanDefect> {
        if text.allSatisfy(\.isWhitespace) { return .failure(.noFormula) }
        if text.count > FormulaLimits.characters { return .failure(.syntax) }
        if hasDecimalComma(text) { return .failure(.syntax) }
        let tokens: [FormulaToken]
        switch FormulaToken.lex(text) {
        case .success(let lexed): tokens = lexed
        case .failure(let defect): return .failure(defect)
        }
        let cellCount = tokens.count {
            if case .cell = $0 { return true }
            return false
        }
        if cellCount > FormulaLimits.cells { return .failure(.syntax) }
        var parser = FormulaParser(tokens: tokens)
        guard let formula = parser.expression(depth: 0), parser.atEnd, !parser.failed else {
            return .failure(.syntax)
        }
        return .success((formula, parser.literals))
    }

    /// A digit, a comma and a digit with no space: a decimal comma, which would silently split an argument. A number
    /// glued after a letter (`C1,2`) is an ID, not a decimal.
    static func hasDecimalComma(_ text: String) -> Bool {
        let characters = Array(text)
        let isDigit = { (character: Character) in character.isASCII && character.isNumber }
        var position = 0
        while position < characters.count {
            guard isDigit(characters[position]) else {
                position += 1
                continue
            }
            let previous: Character? = position > 0 ? characters[position - 1] : nil
            var end = position
            while end < characters.count, isDigit(characters[end]) { end += 1 }
            if end + 1 < characters.count, characters[end] == ".", isDigit(characters[end + 1]) {
                end += 1
                while end < characters.count, isDigit(characters[end]) { end += 1 }
            }
            let free = previous.map { !($0.isLetter || isDigit($0) || $0 == ".") } ?? true
            if free, end + 1 < characters.count, characters[end] == ",", isDigit(characters[end + 1]) { return true }
            position = end
        }
        return false
    }

    /// Every cell the formula names, in order, with repeats, labels included.
    public var cells: [CellID] {
        switch self {
        case .cell(let id): [id]
        case .constant: []
        case .negate(let inner), .rate(let inner), .round(let inner, _): inner.cells
        case .binary(_, let left, let right): left.cells + right.cells
        case .call(_, let arguments): arguments.flatMap(\.cells)
        case .count(let ids): ids
        case .pick(_, let arms): arms.flatMap { $0.value.cells + [$0.label] }
        }
    }

    /// Every literal the formula holds, in order; ROUND's digit count is not one.
    public var constants: [Decimal] {
        switch self {
        case .cell, .count: []
        case .constant(let value): [value]
        case .negate(let inner), .rate(let inner), .round(let inner, _): inner.constants
        case .binary(_, let left, let right): left.constants + right.constants
        case .call(_, let arguments): arguments.flatMap(\.constants)
        case .pick(_, let arms): arms.flatMap(\.value.constants)
        }
    }
}

public enum BinaryOperator: Sendable, Equatable {
    case add
    case subtract
    case multiply
    case divide
}

public enum FormulaFunction: String, Sendable, CaseIterable {
    case sum = "SUM"
    case avg = "AVG"
    case min = "MIN"
    case max = "MAX"
    case abs = "ABS"
}

public enum Pick: String, Sendable, CaseIterable {
    case argmin = "ARGMIN"
    case argmax = "ARGMAX"
}

/// One arm of a pick: `value @ label`.
public struct PickArm: Sendable, Equatable {
    public let value: Formula
    public let label: CellID

    public init(value: Formula, label: CellID) {
        self.value = value
        self.label = label
    }
}

/// b2 §5.3: the parser is recursive and its input untrusted.
enum FormulaLimits {
    static let characters = 4000
    static let cells = 500
    static let depth = 32
}

enum FormulaToken: Equatable {
    case cell(CellID)
    case number(String)
    case name(String)
    case symbol(Character)

    static let names: Set<String> = [
        "SUM", "AVG", "AVERAGE", "MIN", "MAX", "COUNT", "ROUND", "ABS", "ARGMIN", "ARGMAX",
    ]

    /// `−`, `×` and `÷` read as `-`, `*` and `/`; nothing else is mapped.
    static func lex(_ text: String) -> Result<[FormulaToken], PlanDefect> {
        let characters = Array(
            text.map { character -> Character in
                switch character {
                case "\u{2212}": "-"
                case "\u{00D7}": "*"
                case "\u{00F7}": "/"
                default: character
                }
            })
        var tokens: [FormulaToken] = []
        var position = 0
        let isASCIILetter = { (character: Character) in character.isASCII && character.isLetter }
        let isASCIIDigit = { (character: Character) in character.isASCII && character.isNumber }
        while position < characters.count {
            let character = characters[position]
            if character.isWhitespace {
                position += 1
                continue
            }
            if character == "C" || character == "c", position + 1 < characters.count,
                isASCIIDigit(characters[position + 1]), characters[position + 1] != "0"
            {
                var end = position + 1
                while end < characters.count, isASCIIDigit(characters[end]) { end += 1 }
                let glued = end < characters.count && (isASCIILetter(characters[end]) || isASCIIDigit(characters[end]))
                if !glued, let id = CellID("C" + String(characters[(position + 1)..<end])) {
                    tokens.append(.cell(id))
                    position = end
                    continue
                }
            }
            if isASCIIDigit(character) {
                var end = position
                while end < characters.count, isASCIIDigit(characters[end]) { end += 1 }
                if end + 1 < characters.count, characters[end] == ".", isASCIIDigit(characters[end + 1]) {
                    end += 1
                    while end < characters.count, isASCIIDigit(characters[end]) { end += 1 }
                }
                tokens.append(.number(String(characters[position..<end])))
                position = end
                continue
            }
            if isASCIILetter(character) {
                var end = position
                while end < characters.count, isASCIILetter(characters[end]) { end += 1 }
                let name = String(characters[position..<end]).uppercased()
                guard names.contains(name) else { return .failure(.unknownFunction) }
                tokens.append(.name(name))
                position = end
                continue
            }
            guard "+-*/(),%@".contains(character) else { return .failure(.syntax) }
            tokens.append(.symbol(character))
            position += 1
        }
        return .success(tokens)
    }
}

/// Recursive descent over the tokens: `*` `/` over `+` `-`, left to right; unary minus tighter than `*`; postfix `%`
/// tighter than unary minus.
struct FormulaParser {
    let tokens: [FormulaToken]
    var position = 0
    var failed = false
    var literals: [String] = []

    init(tokens: [FormulaToken]) {
        self.tokens = tokens
    }

    var atEnd: Bool { position == tokens.count }

    var peek: FormulaToken? { position < tokens.count ? tokens[position] : nil }

    mutating func take(_ symbol: Character) -> Bool {
        guard peek == .symbol(symbol) else { return false }
        position += 1
        return true
    }

    mutating func expression(depth: Int) -> Formula? {
        guard depth <= FormulaLimits.depth, var value = term(depth: depth) else { return nil }
        while true {
            if take("+") {
                guard let right = term(depth: depth) else { return nil }
                value = .binary(.add, value, right)
            } else if take("-") {
                guard let right = term(depth: depth) else { return nil }
                value = .binary(.subtract, value, right)
            } else {
                return value
            }
        }
    }

    mutating func term(depth: Int) -> Formula? {
        guard var value = unary(depth: depth) else { return nil }
        while true {
            if take("*") {
                guard let right = unary(depth: depth) else { return nil }
                value = .binary(.multiply, value, right)
            } else if take("/") {
                guard let right = unary(depth: depth) else { return nil }
                value = .binary(.divide, value, right)
            } else {
                return value
            }
        }
    }

    mutating func unary(depth: Int) -> Formula? {
        if take("-") { return unary(depth: depth + 1).map { .negate($0) } }
        if take("+") { return unary(depth: depth + 1) }
        guard depth <= FormulaLimits.depth * 4, let value = primary(depth: depth) else { return nil }
        return take("%") ? .rate(value) : value
    }

    mutating func primary(depth: Int) -> Formula? {
        switch peek {
        case .number(let text):
            position += 1
            literals.append(text)
            return literal(text).map { .constant($0) }
        case .cell(let id):
            position += 1
            return .cell(id)
        case .name(let name):
            position += 1
            guard take("(") else { return nil }
            return call(name, depth: depth)
        case .symbol("("):
            position += 1
            guard let inner = expression(depth: depth + 1), take(")") else { return nil }
            return inner
        default:
            return nil
        }
    }

    mutating func call(_ name: String, depth: Int) -> Formula? {
        if let pick = Pick(rawValue: name) {
            var arms: [PickArm] = []
            repeat {
                guard let value = expression(depth: depth + 1), take("@"), case .cell(let label) = peek else {
                    return nil
                }
                position += 1
                arms.append(PickArm(value: value, label: label))
            } while take(",")
            guard take(")"), arms.count >= 2 else { return nil }
            return .pick(pick, arms)
        }
        var arguments: [Formula] = []
        var lastLiteral: String?
        repeat {
            let before = literals.count
            guard let argument = expression(depth: depth + 1) else { return nil }
            lastLiteral = literals.count == before + 1 ? literals.last : nil
            arguments.append(argument)
        } while take(",")
        guard take(")") else { return nil }
        switch name {
        case "COUNT":
            let ids = arguments.compactMap { argument -> CellID? in
                if case .cell(let id) = argument { return id }
                return nil
            }
            return ids.count == arguments.count ? .count(ids) : nil
        case "ABS":
            return arguments.count == 1 ? .call(.abs, arguments) : nil
        case "ROUND":
            guard arguments.count <= 2, let value = arguments.first else { return nil }
            guard arguments.count == 2 else { return .round(value, digits: 0) }
            guard case .constant = arguments[1], let text = lastLiteral, text.count == 1,
                let digits = text.first?.wholeNumberValue, digits <= 6
            else { return nil }
            literals.removeLast()
            return .round(value, digits: digits)
        case "AVG", "AVERAGE":
            return .call(.avg, arguments)
        default:
            return FormulaFunction(rawValue: name).map { .call($0, arguments) }
        }
    }

    func literal(_ text: String) -> Decimal? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return DisplayedNumber.decimal(
            integer: String(parts.first ?? ""), fraction: parts.count > 1 ? String(parts[1]) : "", negative: false)
    }
}
