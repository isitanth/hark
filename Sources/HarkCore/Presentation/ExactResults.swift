import Foundation

// The panel's exact answer with several results (M14, plan §4.4).

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
    /// A failed result's « Compris » line, from the plan; a computed one's is its answer's.
    public let failedUnderstood: String?

    public init(
        id: Int, number: Int?, answer: ExactPresentation?, failure: MathFailure?, highlights: CellHighlights?,
        failedUnderstood: String? = nil
    ) {
        self.id = id
        self.number = number
        self.answer = answer
        self.failure = failure
        self.highlights = highlights
        self.failedUnderstood = failedUnderstood
    }

    /// The « Compris » line, computed or failed.
    public var understood: String? { answer?.understood ?? failedUnderstood }

    /// The block reads cells: it has a cells line, Show/Hide, and its pick moves the layer.
    public var readsCells: Bool { highlights != nil }

    /// Its number picks it (plan §4.4): a computed result, or a failed one whose failure names a cell to show in red.
    /// A failure that names none has nothing to show, so its number is not a control.
    public var isPickable: Bool { answer != nil || highlights != nil }
}

/// What VoiceOver says of several results (plan §4.4): the app builds the sentence from catalog keys.
public struct ResultsAnnouncement: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let number: Int
        /// The figure as VoiceOver says it, a pick's row after it.
        public let spoken: String
    }

    /// The computed results, the ones the sentence counts.
    public let count: Int
    public let items: [Item]
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

    /// Several results, numbered: the panel shows blocks. Nil-numbered, it is 0.1.0's one-result view.
    public var numbered: Bool { blocks.contains { $0.number != nil } }

    /// The parts of VoiceOver's announcement; nil for a lone result, which keeps today's.
    public var announcement: ResultsAnnouncement? {
        guard numbered else { return nil }
        let items = blocks.compactMap { block -> ResultsAnnouncement.Item? in
            guard let number = block.number, let answer = block.answer else { return nil }
            return ResultsAnnouncement.Item(number: number, spoken: answer.spokenResult)
        }
        return ResultsAnnouncement(count: items.count, items: items)
    }

    /// The block a number names, for ⌘1 to ⌘3: the position in the turn, not the conversation's number.
    public func block(at position: Int) -> ExactResultBlock? {
        blocks.indices.contains(position) ? blocks[position] : nil
    }
}

extension AskPresentation {
    /// The turn in review's results, one block per result in the model's order; nil without a computed one. A lone
    /// result in a conversation that gave no other number has no number: 0.1.0's view.
    public static func results(_ utterance: UtteranceContext?, locale: Locale) -> ExactResultsPresentation? {
        guard let utterance, let math = utterance.math, case .read(let sheet) = math.reading,
            !math.results.isEmpty, math.numbers.count == math.results.count,
            math.results.contains(where: { (try? $0.get()) != nil })
        else { return nil }
        let lone = math.results.count == 1 && math.numbers.first == 1
        let kept = utterance.keptResults
        // The plan's own words per result; the composed reply's `%%` line only for a state that has none.
        let understoods: [Int: String] =
            math.understoods.isEmpty
            ? composedUnderstoods(utterance.reply ?? "", numbers: math.numbers)
            : Dictionary(
                zip(math.numbers, math.understoods).filter { !$0.1.isEmpty }, uniquingKeysWith: { first, _ in first })
        let blocks = zip(math.numbers, math.results).enumerated().map { index, pair in
            let (number, outcome) = pair
            switch outcome {
            case .success(let computation):
                let answer = ExactAnswer(computation, sheet: sheet, policy: .standard, fallback: locale, kept: kept)
                return ExactResultBlock(
                    id: index, number: lone ? nil : number,
                    answer: presentation(computation, answer: answer, sheet: sheet), failure: nil,
                    highlights: highlights(computation, utterance: utterance))
            case .failure(let failure):
                return ExactResultBlock(
                    id: index, number: lone ? nil : number, answer: nil, failure: failure,
                    highlights: failureCell(failure, utterance: utterance),
                    failedUnderstood: understoods[number])
            }
        }
        return ExactResultsPresentation(blocks: blocks)
    }

    /// Each result's `understood`, from the composed reply's `%%` line (`PlanPrompt.composedReply`): the text after
    /// its circled number, up to the next one. A failed result keeps no other trace of it.
    static func composedUnderstoods(_ reply: String, numbers: [Int]) -> [Int: String] {
        guard numbers.count > 1, let head = reply.split(separator: "\n", omittingEmptySubsequences: false).first,
            head.hasPrefix(IntentSplit.marker + " ")
        else { return [:] }
        var rest = Substring(head.dropFirst(IntentSplit.marker.count + 1))
        var found: [Int: String] = [:]
        for (index, number) in numbers.enumerated() {
            let mark = ResultMark.circled(number) + " "
            guard rest.hasPrefix(mark) else { return found }
            rest = rest.dropFirst(mark.count)
            let next = index + 1 < numbers.count ? " " + ResultMark.circled(numbers[index + 1]) + " " : nil
            if let next, let range = rest.range(of: next) {
                found[number] = String(rest[..<range.lowerBound])
                rest = rest[rest.index(after: range.lowerBound)...]
            } else {
                found[number] = String(rest)
            }
        }
        return found.filter { !$0.value.isEmpty }
    }
}
