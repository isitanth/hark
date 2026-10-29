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

    /// `fallback` is the user's format for the result (decision 8).
    public init(_ computation: Computation, sheet: CellSheet, policy: RoundingPolicy, fallback: Locale) {
        understood = nil
        working = nil
        result = ""
        exact = nil
        figures = []
    }

    /// The reply as a turn of the conversation keeps it: the `%%` line, then the working, then the result alone.
    public var reply: String {
        ""
    }
}
