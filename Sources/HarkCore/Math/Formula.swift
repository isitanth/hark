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

    public static func parse(_ text: String) -> Result<Formula, PlanDefect> {
        .failure(.syntax)
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
