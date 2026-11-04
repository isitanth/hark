import Foundation

// A result the conversation keeps (M14, plan §4.2): what a later formula's `RES<n>` reads. In memory only.

/// A shown result, kept for the rest of the conversation: never logged, never written, freed with the conversation,
/// and not `Codable` (a check.sh gate). No cell: its `understood` may quote the screen, and is kept like the selection.
public struct KeptResult: Sendable, Equatable {
    /// ①, ②…: given once, on `planned` → `reviewing`, counting on across the conversation; never reused.
    public let number: Int
    /// `Computation.value`, before any display rounding.
    public let value: Decimal
    /// The unit as shown (`RoundingPolicy.displayUnit`): what the algebra gives a reference.
    public let unit: MathUnit
    /// The unit label kept on screen (`UnitLabel.kept`), nil when the result showed bare.
    public let unitLabel: String?
    /// The decimals shown, for `RoundingPolicy.decimals` over a formula that names this result.
    public let scale: Int
    /// The figure as the panel showed it.
    public let shown: String
    public let understood: String
    /// The turn that computed it.
    public let turn: UtteranceID

    public init(
        number: Int, value: Decimal, unit: MathUnit, unitLabel: String?, scale: Int, shown: String,
        understood: String, turn: UtteranceID
    ) {
        self.number = number
        self.value = value
        self.unit = unit
        self.unitLabel = unitLabel
        self.scale = scale
        self.shown = shown
        self.understood = understood
        self.turn = turn
    }
}
