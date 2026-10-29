import Foundation

// The model's plan and its defects (M13, b2 §9, §11). S1 implements this.

/// The unit the model declares for its result.
public enum ResultUnit: String, Sendable, CaseIterable {
    case eur = "EUR"
    case usd = "USD"
    case gbp = "GBP"
    case percent
    case count
    case hours
    case none
}

/// What the model returns under the JSON schema: the restatement it writes, a formula over cell IDs, and the unit.
public struct CalculationPlan: Sendable, Equatable {
    public let understood: String
    public let formula: String
    public let unit: ResultUnit

    public init(understood: String, formula: String, unit: ResultUnit) {
        self.understood = understood
        self.formula = formula
        self.unit = unit
    }

    /// The schema the server is asked to enforce, named `plan` as measured.
    public static let schema = ResponseSchema(name: "plan", json: "{}")

    public static func decode(_ reply: String, finishReason: String?) -> Result<CalculationPlan, PlanDefect> {
        .failure(.json)
    }
}

/// Why a plan cannot be used. Its code carries the reason, never content: the constant a model wrote stays out of it.
public enum PlanDefect: Error, Sendable, Equatable {
    /// The reply is not the schema, or the server refused the schema.
    case json
    /// Cut by the token limit.
    case truncated
    /// The formula does not parse, holds a decimal comma, or passes the limits.
    case syntax
    case unknownFunction
    case unknownCell
    /// A literal neither spoken nor a conversion, as the model wrote it.
    case unspokenConstant(String)
    /// An empty formula: the model says it is not a calculation.
    case noFormula
    /// The units contradict each other, or the declared one.
    case unit
    /// `X − X`, `X ÷ X`, a cell repeated in COUNT.
    case degenerate

    /// The reason in the log's `plan_invalid:<code>`.
    public var code: String {
        switch self {
        case .json: "json"
        case .truncated: "truncated"
        case .syntax: "syntax"
        case .unknownFunction: "unknown_function"
        case .unknownCell: "unknown_cell"
        case .unspokenConstant: "unspoken_constant"
        case .noFormula: "no_formula"
        case .unit: "unit"
        case .degenerate: "degenerate"
        }
    }

    /// One automatic retry, with the defect named (decision 18). Not for an empty formula or a cut reply.
    public var isRetryable: Bool {
        switch self {
        case .json, .syntax, .unknownFunction, .unknownCell, .unspokenConstant, .unit, .degenerate: true
        case .truncated, .noFormula: false
        }
    }

    /// The note the retry sends back to the model: an ID, a constant or a rule, never a cell's text.
    public var correction: String {
        ""
    }
}

/// The retry's payload: the rejected reply goes back to the model with the note that names its defect.
public struct PlanCorrection: Sendable, Equatable {
    public let reply: String
    public let note: String

    public init(reply: String, note: String) {
        self.reply = reply
        self.note = note
    }
}
