import Foundation

// The plan of one to three results (M14, plan §4.1). The contract's stubs; S1 implements them.

/// What the model returns under the M14 schema: `{"results": [one to three of today's plan]}`. A one-result ask is an
/// array of one; today's flat object is accepted as a plan of one, as 0.1.0 accepted a reply without `unit_label`.
public struct PlanSet: Sendable, Equatable {
    /// The decoder's bound: the schema names none (no `maxItems`, plan §4.1).
    public static let maxResults = 3

    public let results: [CalculationPlan]

    public init(results: [CalculationPlan]) {
        self.results = results
    }

    /// The set, or why not: `truncated` for a cut reply; `json` for an empty array, a fourth item, any extra key or a
    /// wrong type, strict per item as `CalculationPlan.decode` is. The contract's stub refuses every reply.
    public static func decode(_ reply: String, finishReason: String?) -> Result<PlanSet, PlanDefect> {
        .failure(.json)
    }
}

/// One result of a plan: computed, or the failure that stopped it alone (plan §4.1). A failed result keeps its number.
public typealias ResultOutcome = Result<Computation, MathFailure>

extension MathEngine {
    /// Every result of the reply, each through today's checks alone, in today's order, with the conversation's kept
    /// results for its `RES` leaves; or a whole-reply defect (`json`, `truncated`) as the failure. `solve` stays the
    /// one-result entry for the golden and parity tests. The contract's stub refuses every reply.
    public static func solveAll(
        reply: String, finishReason: String?, sheet: CellSheet, instruction: String, kept: [KeptResult]
    ) -> Result<[ResultOutcome], MathFailure> {
        .failure(.plan(.json))
    }
}
