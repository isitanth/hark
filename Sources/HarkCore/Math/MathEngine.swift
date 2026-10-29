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
    /// Decodes the model's reply, checks it against the sheet and the spoken instruction, and evaluates it.
    public static func solve(
        reply: String, finishReason: String?, sheet: CellSheet, instruction: String
    ) -> Result<Computation, MathFailure> {
        .failure(.plan(.json))
    }
}
