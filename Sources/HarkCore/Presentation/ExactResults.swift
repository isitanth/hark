import Foundation

// The panel's exact answer with several results (M14, plan §4.4). The contract's stubs; S4 implements them.

/// One result's block: its number (nil while the conversation holds a single result), its answer or its failure,
/// and the cells it read for the layer.
public struct ExactResultBlock: Sendable, Equatable, Identifiable {
    /// ①…: shown from the second result of the conversation on.
    public let number: Int?
    public let answer: ExactPresentation?
    /// Why this result alone was not computed; it keeps its number.
    public let failure: MathFailure?
    /// The cells this result read, or the one its failure names; nil when it reads none (references only).
    public let highlights: CellHighlights?
    /// The position in the turn's results, the block's identity.
    public let id: Int

    public init(
        id: Int, number: Int?, answer: ExactPresentation?, failure: MathFailure?, highlights: CellHighlights?
    ) {
        self.id = id
        self.number = number
        self.answer = answer
        self.failure = failure
        self.highlights = highlights
    }
}

/// The turn's results in the order the model returned them, and what Copy and Insert send.
public struct ExactResultsPresentation: Sendable, Equatable {
    public let blocks: [ExactResultBlock]

    public init(blocks: [ExactResultBlock]) {
        self.blocks = blocks
    }

    /// One figure per line, the computed results only, in order; one result is its figure alone, as 0.1.0 sends it.
    public var copyText: String {
        blocks.compactMap { $0.answer?.result }.joined(separator: "\n")
    }
}

extension AskPresentation {
    /// The turn in review's results. The contract's stub shows none.
    public static func results(_ utterance: UtteranceContext?, locale: Locale) -> ExactResultsPresentation? {
        nil
    }
}
