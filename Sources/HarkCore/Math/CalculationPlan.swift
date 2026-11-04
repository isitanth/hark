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

/// What the model returns under the JSON schema: the restatement it writes, a formula over cell IDs, the unit, and the
/// word the result's unit is written with on screen.
public struct CalculationPlan: Sendable, Equatable {
    public let understood: String
    public let formula: String
    public let unit: ResultUnit
    /// `To`, `kg`, `vCPU` (0.1.0): the model's proposal, shown only where `UnitLabel` finds it on every cell read.
    /// Empty when the model gives none, and in the replies recorded before it.
    public let unitLabel: String

    public init(understood: String, formula: String, unit: ResultUnit, unitLabel: String = "") {
        self.understood = understood
        self.formula = formula
        self.unit = unit
        self.unitLabel = unitLabel
    }

    /// The schema the server is asked to enforce, named `plan` as measured in M14.0
    /// (`docs/acceptance/M14-data/bench/plan-schema-m14.json`, SHA-256 4c6da70c…): a `results` array of 1 to 3 of
    /// today's item, no `minItems` or `maxItems`; the count is the decoder's.
    public static let schema = ResponseSchema(
        name: "plan",
        json: """
            {
              "type": "object",
              "properties": {
                "results": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "understood": {
                        "type": "string"
                      },
                      "formula": {
                        "type": "string"
                      },
                      "unit": {
                        "type": "string",
                        "enum": [
                          "EUR",
                          "USD",
                          "GBP",
                          "percent",
                          "count",
                          "hours",
                          "none"
                        ]
                      },
                      "unit_label": {
                        "type": "string"
                      }
                    },
                    "required": [
                      "understood",
                      "formula",
                      "unit",
                      "unit_label"
                    ],
                    "additionalProperties": false
                  }
                }
              },
              "required": [
                "results"
              ],
              "additionalProperties": false
            }
            """)

    /// The plan, or why not. A cut reply is `truncated` before anything else; one surrounding code fence is removed. A
    /// missing `unit_label` is empty, as in the stub's replies and those recorded before it; prose around the object,
    /// any other missing or extra field, a wrong type or a unit outside the enum is `json`.
    public static func decode(_ reply: String, finishReason: String?) -> Result<CalculationPlan, PlanDefect> {
        if finishReason == "length" { return .failure(.truncated) }
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
            var inner = text.dropFirst(3).dropLast(3)
            if inner.hasPrefix("json") { inner = inner.dropFirst(4) }
            text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).subtracting(["unit_label"]) == ["understood", "formula", "unit"],
            let understood = object["understood"] as? String, let formula = object["formula"] as? String,
            let unitText = object["unit"] as? String, let unit = ResultUnit(rawValue: unitText),
            let unitLabel = (object["unit_label"] ?? "") as? String
        else { return .failure(.json) }
        return .success(CalculationPlan(understood: understood, formula: formula, unit: unit, unitLabel: unitLabel))
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
    /// A `RES` reference (M14) that names no result the conversation keeps, or a failed one.
    case unknownResult
    /// A literal neither spoken nor a conversion, as the model wrote it.
    case unspokenConstant(String)
    /// An empty formula: the model says it is not a calculation.
    case noFormula
    /// The units contradict each other. The note is the frozen engine's (`harness.py`, M13.0 change 1): it names units
    /// in words or in the engine's codes, never a cell's text.
    case unit(String)
    /// The result's unit is not the declared one, or a currency outside the unit list: the frozen engine's note, as
    /// `unit`'s. Apart from `unit` for the words the user reads; the log says `unit` for both.
    case declaredUnit(String)
    /// A percent whose formula does not carry exactly one hundred (0.1.0); the log says `unit`.
    case percentScale
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
        case .unknownResult: "unknown_result"
        case .unspokenConstant: "unspoken_constant"
        case .noFormula: "no_formula"
        case .unit, .declaredUnit, .percentScale: "unit"
        case .degenerate: "degenerate"
        }
    }

    /// One automatic retry, with the defect named (decision 18). Not for an empty formula or a cut reply.
    public var isRetryable: Bool {
        switch self {
        case .json, .syntax, .unknownFunction, .unknownCell, .unknownResult, .unspokenConstant, .unit, .declaredUnit,
            .percentScale, .degenerate:
            true
        case .truncated, .noFormula: false
        }
    }

    /// The note the retry sends back to the model: an ID, a constant or a rule, never a cell's text.
    public var correction: String {
        switch self {
        case .json: "reply with one JSON object with understood, formula, unit and unit_label only"
        case .syntax: "write decimals with a point and use only the listed functions"
        case .unknownFunction: "use only SUM, AVG, MIN, MAX, COUNT, ROUND, ABS, ARGMIN, ARGMAX"
        case .unknownCell: "refer only to IDs from the item list"
        case .unknownResult: "refer only to result IDs from the results list"
        case .unspokenConstant(let literal): "\(literal) is not a number the user said: refer to its item"
        case .unit(let note), .declaredUnit(let note): note
        case .percentScale: "multiply by 100 for a percent"
        case .degenerate: "the formula cancels itself out"
        case .truncated, .noFormula: ""
        }
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
