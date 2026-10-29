import Foundation

// The engine: checks, evaluation in Decimal, the cells' roles (M13, b2 §7). S1 implements this.

/// A cell whose value cannot be computed with.
public enum MathDefect: String, Error, Sendable, CaseIterable {
    case divisionByZero = "division_by_zero"
    case noNumber = "no_number"
    case garbled
    case overflow
}

/// Shown under the answer, never blocking.
public enum MathWarning: Sendable, Equatable {
    case suspiciousCell(CellID)
    case doubt(CellID)
    case scaleMismatch(CellID)
    case dashAsZero(CellID)
    case parenthesized(CellID)
    case approximate
    case assumedConvention
    case tie(CellID)
    case rounded(exact: Decimal)
}

/// How a cell counts in the result, by the sign of its contribution: what the highlights colour.
public enum CellRole: String, Sendable, CaseIterable {
    case added
    case subtracted
    case counted
    case compared
    case rate
}

/// The arm an ARGMIN or ARGMAX chose: its label, and the cells its value read.
public struct Winner: Sendable, Equatable {
    public let label: CellID
    public let read: [CellID]

    public init(label: CellID, read: [CellID]) {
        self.label = label
        self.read = read
    }
}

/// A plan evaluated: the exact value, its unit, and the cells it read.
public struct Computation: Sendable, Equatable {
    public let plan: CalculationPlan
    public let formula: Formula
    /// Exact: only a ROUND in the formula rounds it.
    public let value: Decimal
    public let unit: MathUnit
    /// Distinct, in first-read order.
    public let read: [CellID]
    /// One per cell read; a cell read twice with two roles keeps the first.
    public let roles: [CellID: CellRole]
    public let winner: Winner?
    public let warnings: [MathWarning]

    public init(
        plan: CalculationPlan, formula: Formula, value: Decimal, unit: MathUnit, read: [CellID],
        roles: [CellID: CellRole], winner: Winner?, warnings: [MathWarning]
    ) {
        self.plan = plan
        self.formula = formula
        self.value = value
        self.unit = unit
        self.read = read
        self.roles = roles
        self.winner = winner
        self.warnings = warnings
    }
}

/// Why the exact path stopped: the reader, the plan or the arithmetic.
public enum MathFailure: Error, Sendable, Equatable {
    case reader(ReaderFailure)
    case plan(PlanDefect)
    /// `cell` is the cell at fault, outlined in red; nil when no single cell is.
    case math(MathDefect, cell: CellID?)

    /// The log's code for it. The cell stays out of it.
    public var pipelineFailure: PipelineFailure {
        switch self {
        case .reader(let failure): .readerFailed(failure)
        case .plan(let defect): .planInvalid(defect)
        case .math(let defect, _): .mathError(defect)
        }
    }
}

public enum MathEngine {
    /// Decodes the model's reply, checks it against the sheet and the spoken instruction, and evaluates it. The checks
    /// run in b2 §7's order and the first failure wins, so a retry note names one defect.
    public static func solve(
        reply: String, finishReason: String?, sheet: CellSheet, instruction: String
    ) -> Result<Computation, MathFailure> {
        let plan: CalculationPlan
        switch CalculationPlan.decode(reply, finishReason: finishReason) {
        case .success(let decoded): plan = decoded
        case .failure(let defect): return .failure(.plan(defect))
        }
        let parsed: (formula: Formula, literals: [String])
        switch Formula.parseKeepingLiterals(plan.formula) {
        case .success(let tree): parsed = tree
        case .failure(let defect): return .failure(.plan(defect))
        }
        let formula = parsed.formula
        if formula.cells.contains(where: { sheet[$0] == nil }) { return .failure(.plan(.unknownCell)) }
        let allowed = SpokenNumbers.allowed(in: instruction)
        for (constant, literal) in zip(formula.constants, parsed.literals)
        where !allowed.contains(where: { $0 == constant }) {
            return .failure(.plan(.unspokenConstant(literal)))
        }
        if formula.isDegenerate { return .failure(.plan(.degenerate)) }
        var evaluator = Evaluator(sheet: sheet)
        let result: (value: Decimal, unit: MathUnit)
        do {
            result = try evaluator.evaluate(formula)
            try checkDeclared(result.unit, plan.unit, formula: formula, sheet: sheet)
        } catch {
            return .failure(error)
        }
        let read = evaluator.read.reduce(into: [CellID]()) { if !$0.contains($1) { $0.append($1) } }
        var warnings = evaluator.warnings + warnings(read: read, sheet: sheet)
        let policy = RoundingPolicy.standard
        let unit = RoundingPolicy.displayUnit(result.unit, declared: plan.unit, value: result.value)
        let shown = policy.round(result.value, unit: unit, read: read, sheet: sheet)
        // Against the value snapped as `ExactAnswer.exact` is, so a division residue is no rounding.
        let snapped = RoundingPolicy.round(result.value, scale: RoundingPolicy.snapScale, rule: .halfUp)
        if shown != snapped { warnings.append(.rounded(exact: snapped)) }
        return .success(
            Computation(
                plan: plan, formula: formula, value: result.value, unit: result.unit, read: read,
                roles: CellRoles.of(formula, sheet: sheet), winner: evaluator.winner, warnings: warnings))
    }
}

extension Formula {
    /// `X − X` and `X ÷ X` with structurally equal sides, or a cell repeated in COUNT, anywhere in the tree.
    var isDegenerate: Bool {
        switch self {
        case .cell, .constant: false
        case .negate(let inner), .rate(let inner), .round(let inner, _): inner.isDegenerate
        case .binary(let operation, let left, let right):
            ((operation == .subtract || operation == .divide) && left == right) || left.isDegenerate
                || right.isDegenerate
        case .call(_, let arguments): arguments.contains(where: \.isDegenerate)
        case .count(let ids): Set(ids).count != ids.count
        case .pick(_, let arms): arms.contains { $0.value.isDegenerate }
        }
    }

    /// Without the outer ROUND, ABS and minus signs: where the percent scale check looks.
    /// A factor of 100 in a product, numerators included: the × 100 that makes a ratio a percent.
    var multipliesByHundred: Bool {
        switch stripped {
        case .constant(let value): value == 100
        case .binary(.multiply, let left, let right): left.multipliesByHundred || right.multipliesByHundred
        case .binary(.divide, let numerator, _): numerator.multipliesByHundred
        default: false
        }
    }

    var stripped: Formula {
        switch self {
        case .round(let inner, _), .negate(let inner): inner.stripped
        case .call(.abs, let arguments) where arguments.count == 1: arguments[0].stripped
        default: self
        }
    }
}

/// Depth first, left to right, in Decimal, with b2 §4.3's unit algebra.
struct Evaluator {
    let sheet: CellSheet
    var read: [CellID] = []
    var warnings: [MathWarning] = []
    var winner: Winner?

    init(sheet: CellSheet) {
        self.sheet = sheet
    }

    mutating func evaluate(_ formula: Formula) throws(MathFailure) -> (value: Decimal, unit: MathUnit) {
        let result = try step(formula)
        if result.value.isNaN { throw .math(.overflow, cell: nil) }
        return result
    }

    private mutating func step(_ formula: Formula) throws(MathFailure) -> (value: Decimal, unit: MathUnit) {
        let result = try node(formula)
        if result.value.isNaN { throw .math(.overflow, cell: nil) }
        return result
    }

    private mutating func node(_ formula: Formula) throws(MathFailure) -> (value: Decimal, unit: MathUnit) {
        switch formula {
        case .constant(let value):
            return (value, .number)
        case .cell(let id):
            read.append(id)
            guard let cell = sheet[id] else { throw .plan(.unknownCell) }
            switch cell.reading {
            case .garbled: throw .math(.garbled, cell: id)
            case .text: throw .math(.noNumber, cell: id)
            case .amount(let amount): return (amount.value, MathUnit(amount.unit))
            }
        case .negate(let inner):
            let (value, unit) = try step(inner)
            return (-value, unit)
        case .rate(let inner):
            let (value, unit) = try step(inner)
            return (value / 100, try UnitAlgebra.rate(unit))
        case .binary(let operation, let left, let right):
            let (a, unitA) = try step(left)
            let (b, unitB) = try step(right)
            switch operation {
            case .add: return (a + b, try UnitAlgebra.unify(unitA, unitB))
            case .subtract: return (a - b, try UnitAlgebra.unify(unitA, unitB))
            case .multiply: return (a * b, try UnitAlgebra.multiply(unitA, unitB))
            case .divide:
                let unit = try UnitAlgebra.divide(unitA, unitB)
                if b == 0 {
                    var divisor: CellID?
                    if case .cell(let id) = right.stripped { divisor = id }
                    throw .math(.divisionByZero, cell: divisor)
                }
                return (a / b, unit)
            }
        case .count(let ids):
            read.append(contentsOf: ids)
            return (Decimal(ids.count), .count)
        case .round(let inner, let digits):
            let (value, unit) = try step(inner)
            return (RoundingPolicy.round(value, scale: digits, rule: .halfUp), unit)
        case .call(let function, let arguments):
            var values: [(Decimal, MathUnit)] = []
            for argument in arguments { values.append(try step(argument)) }
            var unit = values[0].1
            for other in values.dropFirst() { unit = try UnitAlgebra.unify(unit, other.1) }
            let numbers = values.map(\.0)
            switch function {
            case .abs: return (numbers[0] < 0 ? -numbers[0] : numbers[0], unit)
            case .sum: return (numbers.reduce(0, +), unit)
            case .avg: return (numbers.reduce(0, +) / Decimal(numbers.count), unit)
            case .min: return (numbers.min() ?? 0, unit)
            case .max: return (numbers.max() ?? 0, unit)
            }
        case .pick(let pick, let arms):
            var results: [(value: Decimal, unit: MathUnit, label: CellID, read: [CellID])] = []
            for arm in arms {
                let start = read.count
                let (value, unit) = try step(arm.value)
                read.append(arm.label)
                let armRead = read[start...].reduce(into: [CellID]()) { if !$0.contains($1) { $0.append($1) } }
                results.append((value, unit, arm.label, armRead))
            }
            var unit = results[0].unit
            for other in results.dropFirst() { unit = try UnitAlgebra.unify(unit, other.unit) }
            let values = results.map(\.value)
            let best = (pick == .argmin ? values.min() : values.max()) ?? 0
            let winners = results.filter { $0.value == best }
            let chosen = winners[0]
            if winners.count > 1 { warnings.append(.tie(chosen.label)) }
            winner = Winner(label: chosen.label, read: chosen.read)
            return (chosen.value, unit)
        }
    }
}

/// b2 §4.3, as `harness._unify`, `_mul`, `_div` and `_pct` froze it. Everything not listed is `plan_invalid:unit`,
/// with the frozen engine's note.
enum UnitAlgebra {
    static func unify(_ a: MathUnit, _ b: MathUnit) throws(MathFailure) -> MathUnit {
        if a == b { return a }
        if a == .number { return b }
        if b == .number { return a }
        throw .plan(.unit("\(a.code) and \(b.code) cannot be added or compared"))
    }

    static func multiply(_ a: MathUnit, _ b: MathUnit) throws(MathFailure) -> MathUnit {
        if a == .number { return b }
        if b == .number { return a }
        switch (a, b) {
        case (.count, .count): return .number
        case (.count, .money), (.count, .hours): return b
        case (.money, .count), (.hours, .count): return a
        case (.hours, .money): return b
        case (.money, .hours): return a
        default:
            let rate = a == .percent || b == .percent ? "; write the rate as an item with %" : ""
            throw .plan(.unit("\(a.code) times \(b.code) is refused" + rate))
        }
    }

    static func divide(_ a: MathUnit, _ b: MathUnit) throws(MathFailure) -> MathUnit {
        if b == .number { return a }
        if a == b { return .number }
        switch (a, b) {
        case (.money, .count), (.money, .hours): return a
        case (.number, .count): return .number
        default: throw .plan(.unit("\(a.code) divided by \(b.code) is refused"))
        }
    }

    static func rate(_ a: MathUnit) throws(MathFailure) -> MathUnit {
        guard a == .percent || a == .number else { throw .plan(.unit("\(a.code) cannot take %")) }
        return .number
    }
}

extension MathEngine {
    /// The one currency every money cell of the frame shows, if there is one.
    static func regionCurrency(_ sheet: CellSheet) -> Currency? {
        let currencies = Set(
            sheet.cells.compactMap { cell -> Currency? in
                guard case .amount(let amount) = cell.reading, case .money(let currency) = amount.unit else {
                    return nil
                }
                return currency
            })
        return currencies.count == 1 ? currencies.first : nil
    }

    /// b2 §4.4, and the percent scale check: a percent declared over a quotient of like units with no `× 100`.
    static func checkDeclared(
        _ unit: MathUnit, _ declared: ResultUnit, formula: Formula, sheet: CellSheet
    ) throws(MathFailure) {
        let currency: Currency? =
            switch declared {
            case .eur: .eur
            case .usd: .usd
            case .gbp: .gbp
            default: nil
            }
        if let currency {
            if unit == .money(currency) { return }
            if unit == .number, regionCurrency(sheet).map({ $0 == currency }) ?? true { return }
            if case .money(let other) = unit, !["EUR", "USD", "GBP"].contains(other.code) {
                throw .plan(.unit("the result is \(unit.words), which is not in the unit list: write none"))
            }
            throw .plan(.unit("the result is \(unit.words), not \(declared.rawValue)"))
        }
        switch (declared, unit) {
        case (.none, _), (.percent, .percent), (.count, .count), (.count, .number), (.hours, .hours),
            (.hours, .number):
            return
        case (.percent, .number):
            guard case .binary(.divide, let top, let bottom) = formula.stripped else { return }
            var left = Evaluator(sheet: sheet)
            var right = Evaluator(sheet: sheet)
            guard let a = try? left.evaluate(top).unit, let b = try? right.evaluate(bottom).unit else { return }
            // `100 * C1 / C2` holds its hundred in the numerator: it is a percent already.
            if a == b, a != .number, !top.multipliesByHundred {
                throw .plan(.unit("multiply by 100 for a percent"))
            }
        default:
            throw .plan(.unit("the result is \(unit.words), not \(declared.rawValue)"))
        }
    }

    /// The marks a reader leaves on the cells read: shown under the answer, never blocking.
    static func warnings(read: [CellID], sheet: CellSheet) -> [MathWarning] {
        var warnings: [MathWarning] = []
        var approximate = false
        var assumed = false
        var columns: [String: [(CellID, Int)]] = [:]
        for id in read {
            guard let cell = sheet[id] else { continue }
            if cell.suspicious { warnings.append(.suspiciousCell(id)) }
            guard case .amount(let amount) = cell.reading else { continue }
            if amount.notes.contains(.doubt) || hasDoubtfulCharacter(cell.text) { warnings.append(.doubt(id)) }
            if amount.notes.contains(.dashAsZero) { warnings.append(.dashAsZero(id)) }
            if amount.notes.contains(.parenthesized) { warnings.append(.parenthesized(id)) }
            approximate = approximate || amount.notes.contains(.approximate)
            assumed = assumed || amount.notes.contains(.assumedConvention)
            switch amount.unit {
            case .money, .number:
                let column = cell.table.flatMap { table in cell.column.map { "\(table).\($0)" } } ?? "lines"
                columns["\(column) \(amount.unit)", default: []].append((id, amount.scale))
            case .percent, .hours: break
            }
        }
        // A figure read with fewer decimals than the others read in its column: c07's `1 089,9` among `,dd` amounts.
        for shown in columns.values.sorted(by: { ($0.first?.0 ?? CellID(0)) < ($1.first?.0 ?? CellID(0)) })
        where shown.count >= 3 && shown.contains(where: { $0.1 > 0 }) {
            var counts: [Int: Int] = [:]
            for (_, scale) in shown { counts[scale, default: 0] += 1 }
            let usual = counts.max { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }?.key ?? 0
            warnings += shown.filter { $0.1 < usual }.map { .scaleMismatch($0.0) }
        }
        if approximate { warnings.append(.approximate) }
        if assumed { warnings.append(.assumedConvention) }
        return warnings
    }

    /// `harness._DOUBT`: a character outside Latin-1 and the usual typography, beside digits, minus the spaces.
    static func hasDoubtfulCharacter(_ text: String) -> Bool {
        guard text.contains(where: \.isNumber) else { return false }
        let usual: Set<Character> = [
            "€", "−", "–", "—", "•", "·", "’", "‘", "“", "”", "…", "›", "‹", "▾", "×", "→", "←", "°", "№",
        ]
        return text.contains { character in
            guard let scalar = character.unicodeScalars.first, scalar.value > 0xFF else { return false }
            return !usual.contains(character) && !DisplayedNumber.spaceLike.contains(character)
                && !DisplayedNumber.minusSigns.contains(character)
        }
    }
}

/// Each cell's role by the sign of its contribution (b4 §6.2). In a linear position the coefficient's sign times the
/// value's sign; past a product of cells or a cell divisor, the sign of the partial derivative. A cell read twice
/// keeps its first role.
struct CellRoles {
    let sheet: CellSheet
    var roles: [CellID: CellRole] = [:]

    static func of(_ formula: Formula, sheet: CellSheet) -> [CellID: CellRole] {
        var walker = CellRoles(sheet: sheet)
        walker.walk(formula, coefficient: 1, linear: true)
        return walker.roles
    }

    mutating func assign(_ id: CellID, _ role: CellRole) {
        if roles[id] == nil { roles[id] = role }
    }

    func value(_ formula: Formula) -> Decimal {
        var evaluator = Evaluator(sheet: sheet)
        return (try? evaluator.evaluate(formula).value) ?? 0
    }

    func sign(_ value: Decimal) -> Int { value < 0 ? -1 : 1 }

    mutating func walk(_ formula: Formula, coefficient: Int, linear: Bool) {
        switch formula {
        case .constant:
            return
        case .cell(let id):
            let valueSign = linear ? sign(value(formula)) : 1
            assign(id, coefficient * valueSign > 0 ? .added : .subtracted)
        case .negate(let inner):
            walk(inner, coefficient: -coefficient, linear: linear)
        case .rate(let inner):
            for id in inner.cells { assign(id, .rate) }
        case .round(let inner, _):
            walk(inner, coefficient: coefficient, linear: linear)
        case .count(let ids):
            for id in ids { assign(id, .counted) }
        case .binary(.add, let left, let right):
            walk(left, coefficient: coefficient, linear: linear)
            walk(right, coefficient: coefficient, linear: linear)
        case .binary(.subtract, let left, let right):
            walk(left, coefficient: coefficient, linear: linear)
            walk(right, coefficient: -coefficient, linear: linear)
        case .binary(.multiply, let left, let right):
            let leftConstant = left.cells.isEmpty
            let rightConstant = right.cells.isEmpty
            let still = linear && (leftConstant || rightConstant)
            walk(left, coefficient: coefficient * sign(value(right)), linear: still)
            walk(right, coefficient: coefficient * sign(value(left)), linear: still)
        case .binary(.divide, let left, let right):
            let still = linear && right.cells.isEmpty
            walk(left, coefficient: coefficient * sign(value(right)), linear: still)
            walk(right, coefficient: -coefficient * sign(value(left)), linear: false)
        case .call(.abs, let arguments):
            for argument in arguments {
                walk(argument, coefficient: coefficient * sign(value(argument)), linear: linear)
            }
        case .call(.sum, let arguments), .call(.avg, let arguments):
            for argument in arguments { walk(argument, coefficient: coefficient, linear: linear) }
        case .call(let extreme, let arguments):
            let values = arguments.map(value)
            let best = (extreme == .min ? values.min() : values.max()) ?? 0
            let chosen = values.firstIndex(of: best) ?? 0
            for (index, argument) in arguments.enumerated() where index != chosen {
                for id in argument.cells { assign(id, .compared) }
            }
            walk(arguments[chosen], coefficient: coefficient, linear: linear)
        case .pick(let pick, let arms):
            let values = arms.map { value($0.value) }
            let best = (pick == .argmin ? values.min() : values.max()) ?? 0
            let chosen = values.firstIndex(of: best) ?? 0
            for (index, arm) in arms.enumerated() where index != chosen {
                for id in arm.value.cells + [arm.label] { assign(id, .compared) }
            }
            walk(arms[chosen].value, coefficient: coefficient, linear: linear)
            assign(arms[chosen].label, coefficient * sign(values[chosen]) > 0 ? .added : .subtracted)
        }
    }
}

extension MathUnit {
    /// The frozen engine's code for a unit, as its algebra notes name it (`harness.cell_unit`).
    var code: String {
        switch self {
        case .money(let currency): "M:" + currency.code
        case .percent: "P"
        case .count: "k"
        case .hours: "H"
        case .number: "n"
        }
    }

    /// A unit in words, as the frozen engine's declared-unit notes name it (`harness.unit_words`).
    var words: String {
        switch self {
        case .money(let currency): "an amount in " + currency.code
        case .percent: "a percent"
        case .count: "a count"
        case .hours: "hours"
        case .number: "a plain number"
        }
    }
}
