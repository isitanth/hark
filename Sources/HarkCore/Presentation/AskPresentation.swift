import CoreGraphics
import Foundation

/// What the Ask panel shows.
public enum AskPanelState: Sendable, Equatable {
    /// No ask in flight, or its answer is being applied: the panel is closed and the caller is brought back.
    case closed
    case listening
    case transcribing
    /// The instruction is heard; a drag is still open and the request waits for the framed region.
    case awaitingRegion
    /// The request is out and no word has come yet.
    case thinking
    case streaming
    /// The answer is complete and editable.
    case reviewing
    case failed(LLMFailure)
    /// The framed region did not become an image.
    case regionFailed(RegionFailure)
    /// An exact ask (M13): the frame's cells are being read.
    case reading
    /// An exact ask: the plan request is out.
    case planning
    /// An exact ask: the read, the plan or the arithmetic failed.
    case mathFailed(MathFailure)
}

/// What the reviewed answer can do besides Copy.
public enum AskApply: Sendable, Equatable {
    /// An ask about a selection: the answer goes in its place.
    case replace
    /// The assistant with a text field focused at the press: the answer goes in at the caret.
    case insert
    /// The assistant with nowhere to write: Copy is the only way out.
    case copyOnly
}

/// The Ask panel's state from the pipeline alone, so HarkApp renders it and computes nothing.
public enum AskPresentation {
    /// How long "Thinking…" stands alone before it names the server it waits for.
    public static let namesServerAfter = Duration.seconds(3)
    /// The same for an ask that sent a frame: reading an image takes a local model 10 to 15 s before the first word
    /// (M11 live checks), a wait that is normal, not a server that is stuck.
    public static let namesServerAfterFrame = Duration.seconds(10)

    /// - Parameter streamed: the answer so far (`PipelineController.askUpdates`) holds text for this utterance.
    public static func state(_ snapshot: PipelineSnapshot, streamed: Bool) -> AskPanelState {
        guard let utterance = snapshot.utterance, utterance.intent.isAsk else { return .closed }
        switch snapshot.phase {
        case .capturing:
            return .listening
        case .transcribing:
            return .transcribing
        case .asking:
            switch snapshot.ask?.stage {
            case .awaitingRegion?: return .awaitingRegion
            case .generating?: return streamed ? .streaming : .thinking
            case .reviewing?: return .reviewing
            case .failed(let failure)?: return .failed(failure)
            case .regionFailed(let failure)?: return .regionFailed(failure)
            case .reading?: return .reading
            case .planning?: return .planning
            case .mathFailed(let failure)?: return .mathFailed(failure)
            case .replacing?, nil: return .closed
            }
        case .idle, .resolving, .confirming, .acting, .inserting, .copying:
            return .closed
        }
    }

    /// Insert is offered when the probe at the press found, in the app the key was pressed in, somewhere a paste or an
    /// AX insertion would land (the rule the panel's Paste follows), and not in a secure field. An ask that carries a
    /// framed region never offers Replace: an image has no text to replace. About a selection, it offers Copy alone:
    /// the selection is still selected in the caller, so Insert would paste over it (M11 review R2). A conversation
    /// follows the same rule from its first framed turn on (M12).
    public static func apply(_ utterance: UtteranceContext?) -> AskApply {
        switch utterance?.intent {
        case .assist(let caller)?:
            return insertOrCopy(utterance, caller: caller)
        case .ask? where utterance?.region != nil || utterance?.thread?.framed == true:
            return .copyOnly
        case .ask?, .dictate?, nil: return .replace
        }
    }

    private static func insertOrCopy(_ utterance: UtteranceContext?, caller: AppIdentity?) -> AskApply {
        guard let caller, utterance?.focus?.app?.processID == caller.processID,
            FocusResolver.pastePlan(focus: utterance?.focus) != nil
        else { return .copyOnly }
        return .insert
    }

    /// The selection as the panel quotes it: its first two lines' worth, whitespace collapsed.
    public static func quote(_ selection: String, limit: Int = 160) -> String {
        let collapsed = selection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(limit) + "…"
    }
}

/// One earlier turn of a conversation, as the panel's transcript shows it: folded to its instruction and one line of
/// the answer (`foldedLine`) until a click unfolds it.
public struct AskTurnRow: Sendable, Equatable, Identifiable {
    public let id: UtteranceID
    /// What the model got for this turn.
    public let instruction: String
    /// The reply's `%%` line, from the first framed turn on; nil before, or when the reply has none.
    public let restatement: String?
    /// The reply without its restatement.
    public let answer: String
    /// The frame this turn brought; the panel finds its thumbnail by the row's id.
    public let region: RegionSummary?

    public init(id: UtteranceID, instruction: String, restatement: String?, answer: String, region: RegionSummary?) {
        self.id = id
        self.instruction = instruction
        self.restatement = restatement
        self.answer = answer
        self.region = region
    }

    /// The line the folded row shows: the answer's first line with words. Under the image rules (a turn with a
    /// restatement) a computed answer ends with its result alone on the last line, after the working: when that last
    /// line holds a figure and is not a list's last item ("- Launch on October 14"), the row shows it instead of the
    /// working's first line.
    public var foldedLine: String {
        let lines = answer.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if restatement != nil, lines.count > 1, let last = lines.last, last.contains(where: \.isNumber),
            last.prefixMatch(of: /(?:[-•*–]|[0-9]+[.)])\s/) == nil
        {
            return last
        }
        return lines.first ?? ""
    }
}

/// The footer's line while an answer is in review.
public enum AskFooterHint: Sendable, Equatable {
    /// The Ask key asks again in the same conversation; `turn` of `of` turns are taken.
    case followUp(turn: Int, of: Int)
    /// The conversation holds as many turns, or as much history, as it may: Copy, Replace or Esc end it.
    case full
}

extension AskPresentation {
    /// How long the busy nudge stays: a talk key pressed while the panel shows.
    public static let busyNudgeFor = Duration.seconds(2)

    /// The nudge shows only over an open panel; with the panel closed a busy press says nothing, as before M12.
    public static func showsBusyNudge(_ state: AskPanelState) -> Bool { state != .closed }

    /// The utterance the panel's reset keys on: turn 1 of the conversation, so a follow-up keeps the earlier turns.
    public static func threadRoot(_ utterance: UtteranceContext) -> UtteranceID {
        utterance.thread?.rootID ?? utterance.id
    }

    /// The earlier turns, oldest first: the thread's answered turns, then the parked one during a follow-up. From the
    /// first framed turn on, every reply carries a `%%` restatement, which the row shows apart.
    public static func earlierTurns(_ utterance: UtteranceContext?) -> [AskTurnRow] {
        guard let utterance else { return [] }
        var framed = false
        var rows: [AskTurnRow] = []
        for turn in utterance.thread?.turns ?? [] {
            framed = framed || turn.region != nil
            rows.append(row(turn.id, turn.instruction, turn.reply, turn.region, framed: framed))
        }
        if let parked = utterance.parked {
            let context = parked.context
            framed = framed || context.region != nil
            rows.append(
                row(
                    context.id, context.request ?? parked.transcript.raw, context.reply ?? "", context.region,
                    framed: framed))
        }
        return rows
    }

    private static func row(
        _ id: UtteranceID, _ instruction: String, _ reply: String, _ region: RegionSummary?, framed: Bool
    ) -> AskTurnRow {
        guard framed else {
            return AskTurnRow(id: id, instruction: instruction, restatement: nil, answer: reply, region: region)
        }
        let split = IntentSplit.split(reply, complete: true)
        return AskTurnRow(
            id: id, instruction: instruction, restatement: split.intent, answer: split.answer, region: region)
    }

    /// The live turn's reply starts with a restatement: this turn sent a frame, or an earlier one did.
    public static func expectsRestatement(_ utterance: UtteranceContext) -> Bool {
        utterance.sentContext?.contains("region") == true || utterance.thread?.framed == true
    }

    /// Replace is offered only while no turn has carried a frame: an image has no text to replace.
    public static func allowsReplace(_ utterance: UtteranceContext) -> Bool {
        utterance.region == nil && !expectsRestatement(utterance)
    }

    /// Ask without the image, after a failure: only when this turn's frame is the conversation's only one. With an
    /// earlier frame the retry would carry it again and fail the same way.
    public static func offersAskWithoutImage(_ utterance: UtteranceContext) -> Bool {
        utterance.region != nil && utterance.earlierFrames.count == 0 && utterance.thread?.framed != true
    }

    /// The turns whose thumbnails the panel keeps, by the controller's rule for the pixels: the live turn with a frame
    /// (or one on its way), the parked turn with one, and the thread's framed turns.
    public static func framedTurns(_ utterance: UtteranceContext?) -> Set<UtteranceID> {
        guard let utterance else { return [] }
        var ids = Set(utterance.thread?.turns.filter { $0.region != nil }.map(\.id) ?? [])
        if utterance.region != nil || utterance.regionPending { ids.insert(utterance.id) }
        if let parked = utterance.parked?.context, parked.region != nil { ids.insert(parked.id) }
        return ids
    }

    /// The footer's line, in review only: how to follow up and the turns taken, or that the conversation is full.
    public static func footerHint(_ snapshot: PipelineSnapshot) -> AskFooterHint? {
        guard state(snapshot, streamed: true) == .reviewing, let utterance = snapshot.utterance else { return nil }
        if utterance.conversationFull(instruction: snapshot.ask?.instruction ?? "") { return .full }
        return .followUp(turn: utterance.conversationTurns, of: AskThread.maxTurns)
    }
}

/// The cells an exact answer read, drawn over the frame on screen (M13): the lens.
public struct CellHighlights: Sendable, Equatable {
    /// The turn whose frame the sheet was read from: the lens asks for that frame's pixels.
    public let frameID: UtteranceID
    /// `CGDirectDisplayID` of the frame's display.
    public let displayID: UInt32
    /// The frame, as `RegionSummary.rect` holds it: the display's points, top-left origin.
    public let frame: CGRect
    public let cells: [HighlightedCell]

    public init(frameID: UtteranceID, displayID: UInt32, frame: CGRect, cells: [HighlightedCell]) {
        self.frameID = frameID
        self.displayID = displayID
        self.frame = frame
        self.cells = cells
    }

    /// Whether a point in Cocoa's global coordinates (bottom-left origin, the main display's) falls on the frame,
    /// edges included. `displayFrame` is the frame's display in the same coordinates (`NSScreen.frame`).
    public func contains(cocoaPoint point: CGPoint, displayFrame: CGRect) -> Bool {
        let x = point.x - displayFrame.minX
        let y = displayFrame.maxY - point.y
        return x >= frame.minX && x <= frame.maxX && y >= frame.minY && y <= frame.maxY
    }
}

/// One cell of the lens: where it is and how it counts.
public struct HighlightedCell: Sendable, Equatable {
    public let id: CellID
    /// The display's points, top-left origin, padded by `AskPresentation.cellPadding`.
    public let box: CGRect
    /// Nil for the cell a failure names: drawn red.
    public let role: CellRole?
    /// The reader could not confirm it: drawn dashed.
    public let uncertain: Bool

    public init(id: CellID, box: CGRect, role: CellRole?, uncertain: Bool) {
        self.id = id
        self.box = box
        self.role = role
        self.uncertain = uncertain
    }
}

/// Decision 17: a figure the understood line names that no cell read holds.
public enum UnderstoodCheck: Sendable, Equatable {
    /// It came from the user's words.
    case spoken(String)
    /// Neither the cells used nor the words hold it.
    case notRead(String)
}

/// One cell read, as the disclosure under an exact answer lists it.
public struct ExactCellRow: Sendable, Equatable, Identifiable {
    public let id: CellID
    public let role: CellRole
    /// The text exactly as read.
    public let text: String
    /// The row's other cells that hold no number, joined by " · ", at most `AskPresentation.labelLimit` characters.
    public let label: String
    public let uncertain: Bool

    public init(id: CellID, role: CellRole, text: String, label: String, uncertain: Bool) {
        self.id = id
        self.role = role
        self.text = text
        self.label = label
        self.uncertain = uncertain
    }
}

/// What the panel shows of an answer Hark computed (M13).
public struct ExactPresentation: Sendable, Equatable {
    public let understood: String?
    public let understoodCheck: UnderstoodCheck?
    /// In the Language & Region format (decision 8): the figure alone, what Copy and Insert send.
    public let result: String
    /// A top-level pick's row label, shown after the figure.
    public let winner: String?
    /// The unrounded value, when rounding changed it: for the help and VoiceOver.
    public let exact: String?
    /// In the document's format, as read; nil for a COUNT or past 12 terms.
    public let working: String?
    public let cellsUsed: Int
    public let added: Int
    public let subtracted: Int
    public let rows: [ExactCellRow]
    /// Two at most with the understood check, in `AskPresentation.checkRank`'s order. Never `rounded`.
    public let checks: [MathWarning]
    /// The text as read of each cell a check names, for its line.
    public let named: [CellID: String]

    public init(
        understood: String?, understoodCheck: UnderstoodCheck?, result: String, winner: String? = nil, exact: String?,
        working: String?, cellsUsed: Int, added: Int, subtracted: Int, rows: [ExactCellRow], checks: [MathWarning],
        named: [CellID: String]
    ) {
        self.understood = understood
        self.understoodCheck = understoodCheck
        self.result = result
        self.winner = winner
        self.exact = exact
        self.working = working
        self.cellsUsed = cellsUsed
        self.added = added
        self.subtracted = subtracted
        self.rows = rows
        self.checks = checks
        self.named = named
    }

    /// The signs line shows only when the result both adds and subtracts.
    public var showsSigns: Bool { added > 0 && subtracted > 0 }

    /// The result as VoiceOver says it: the figure, then a pick's row.
    public var spokenResult: String {
        winner.map { result + ", " + $0 } ?? result
    }
}

extension AskPresentation {
    /// How far a highlight reaches past the cell's box, in points.
    public static let cellPadding: CGFloat = 2
    /// A row label's longest length, its "…" included.
    public static let labelLimit = 40
    /// The check lines under an exact answer, the understood check among them.
    public static let maxChecks = 2

    /// The cells an exact answer read, for the lens; nil without one. In a follow-up, the frame of the turn whose
    /// sheet was planned over.
    public static func highlights(_ utterance: UtteranceContext?) -> CellHighlights? {
        guard let utterance, let computation = utterance.math?.computation,
            let (sheet, frameID, region) = framedSheet(utterance)
        else { return nil }
        let cells = computation.read.compactMap { id -> HighlightedCell? in
            guard let cell = sheet[id] else { return nil }
            return HighlightedCell(
                id: id, box: box(cell.box, in: region.rect), role: computation.roles[id] ?? .added,
                uncertain: uncertain(cell, computation.warnings))
        }
        return CellHighlights(frameID: frameID, displayID: region.displayID, frame: region.rect, cells: cells)
    }

    /// The one cell a math failure names, outlined red; nil when no single cell is at fault or it is not in the sheet.
    public static func failureCell(_ failure: MathFailure, utterance: UtteranceContext?) -> CellHighlights? {
        guard case .math(let defect, let id?) = failure, defect != .overflow, let utterance,
            let (sheet, frameID, region) = framedSheet(utterance), let cell = sheet[id]
        else { return nil }
        let highlighted = HighlightedCell(id: id, box: box(cell.box, in: region.rect), role: nil, uncertain: false)
        return CellHighlights(frameID: frameID, displayID: region.displayID, frame: region.rect, cells: [highlighted])
    }

    /// The exact answer as S1 writes it, for the panel; nil without one.
    public static func exactAnswer(_ utterance: UtteranceContext?, locale: Locale) -> ExactAnswer? {
        guard let math = utterance?.math, let computation = math.computation, case .read(let sheet) = math.reading
        else { return nil }
        return ExactAnswer(computation, sheet: sheet, policy: .standard, fallback: locale)
    }

    /// The panel's exact answer; nil unless the live turn has a computation. `locale` is the user's Language & Region.
    public static func exact(_ utterance: UtteranceContext?, locale: Locale) -> ExactPresentation? {
        guard let math = utterance?.math, let computation = math.computation, case .read(let sheet) = math.reading,
            let answer = exactAnswer(utterance, locale: locale)
        else { return nil }
        let roles = computation.read.map { computation.roles[$0] ?? .added }
        let check = understoodCheck(answer.figures)
        let shown = checks(computation.warnings, limit: maxChecks - (check == nil ? 0 : 1))
        return ExactPresentation(
            understood: answer.understood, understoodCheck: check, result: answer.result, winner: answer.winner,
            exact: answer.exact,
            working: answer.working, cellsUsed: computation.read.count,
            added: roles.filter { $0 == .added || $0 == .counted }.count,
            subtracted: roles.filter { $0 == .subtracted }.count,
            rows: rows(computation, sheet: sheet), checks: shown,
            named: Dictionary(
                shown.compactMap { $0.cell.flatMap { id in sheet[id].map { (id, $0.text) } } },
                uniquingKeysWith: { first, _ in first }))
    }

    /// The first figure the understood line names that no cell read holds.
    public static func understoodCheck(_ figures: [UnderstoodFigure]) -> UnderstoodCheck? {
        for figure in figures {
            switch figure.source {
            case .cell: continue
            case .spoken: return .spoken(figure.text)
            case .nowhere: return .notRead(figure.text)
            }
        }
        return nil
    }

    /// The order the check lines come in.
    static func checkRank(_ warning: MathWarning) -> Int? {
        switch warning {
        case .suspiciousCell: 0
        case .doubt: 1
        case .scaleMismatch: 2
        case .dashAsZero: 3
        case .parenthesized: 4
        case .approximate: 5
        case .assumedConvention: 6
        case .tie: 7
        case .rounded: nil
        }
    }

    /// `suspiciousCell` says the same words for every cell, so it is one line however many cells it names.
    public static func checks(_ warnings: [MathWarning], limit: Int) -> [MathWarning] {
        var seenSuspicious = false
        let ranked = warnings.enumerated().compactMap { offset, warning -> (Int, Int, MathWarning)? in
            guard let rank = checkRank(warning) else { return nil }
            if case .suspiciousCell = warning {
                if seenSuspicious { return nil }
                seenSuspicious = true
            }
            return (rank, offset, warning)
        }
        return ranked.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(max(limit, 0)).map(\.2)
    }

    static func rows(_ computation: Computation, sheet: CellSheet) -> [ExactCellRow] {
        let cells = computation.read.compactMap { sheet[$0] }
        return readingOrder(cells).map { cell in
            ExactCellRow(
                id: cell.id, role: computation.roles[cell.id] ?? .added, text: cell.text,
                label: label(of: cell, in: sheet), uncertain: uncertain(cell, computation.warnings))
        }
    }

    /// Top to bottom, then left to right: two boxes whose middles are within half the smaller height share a line.
    static func readingOrder(_ cells: [Cell]) -> [Cell] {
        var lines: [[Cell]] = []
        for cell in cells.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let last = lines.last?.last,
                abs(last.box.midY - cell.box.midY) <= min(last.box.height, cell.box.height) / 2
            {
                lines[lines.count - 1].append(cell)
            } else {
                lines.append([cell])
            }
        }
        return lines.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    /// The row's cells that hold words, left to right; empty for a line outside every table. A garbled number is no
    /// word, so it never names the row.
    static func label(of cell: Cell, in sheet: CellSheet) -> String {
        guard let table = cell.table, let row = cell.row else { return "" }
        let words = sheet.cells.filter { mate in
            guard mate.id != cell.id, mate.table == table, mate.row == row else { return false }
            guard case .text = mate.reading else { return false }
            return !mate.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let joined = words.sorted { ($0.column ?? 0, $0.box.minX) < ($1.column ?? 0, $1.box.minX) }
            .map { $0.text.split(whereSeparator: \.isNewline).joined(separator: " ") }
            .joined(separator: " · ")
        guard joined.count > labelLimit else { return joined }
        return joined.prefix(labelLimit - 1) + "…"
    }

    static func uncertain(_ cell: Cell, _ warnings: [MathWarning]) -> Bool {
        cell.suspicious
            || warnings.contains {
                switch $0 {
                case .suspiciousCell(let id), .doubt(let id), .scaleMismatch(let id): id == cell.id
                default: false
                }
            }
    }

    static func box(_ normalized: CGRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + normalized.minX * frame.width, y: frame.minY + normalized.minY * frame.height,
            width: normalized.width * frame.width, height: normalized.height * frame.height
        ).insetBy(dx: -cellPadding, dy: -cellPadding)
    }

    /// The live turn's sheet and the turn whose frame it was read from: the live turn's own frame, or in a follow-up
    /// that planned over an earlier sheet, the latest turn that framed it.
    static func framedSheet(_ utterance: UtteranceContext) -> (CellSheet, UtteranceID, RegionSummary)? {
        guard case .read(let sheet) = utterance.math?.reading else { return nil }
        if let region = utterance.region { return (sheet, utterance.id, region) }
        if let parked = utterance.parked?.context, let region = parked.region,
            case .read(let parkedSheet) = parked.math?.reading, parkedSheet == sheet
        {
            return (sheet, parked.id, region)
        }
        guard let turn = utterance.thread?.turns.last(where: { $0.region != nil && $0.sheet == sheet }),
            let region = turn.region
        else { return nil }
        return (sheet, turn.id, region)
    }
}

extension AskPresentation {
    /// The text of the cell a `noNumber` or `garbled` failure names, as read, for its line; nil when the cell is not
    /// known, and the line falls back to the generic one.
    public static func failureCellText(_ failure: MathFailure, utterance: UtteranceContext?) -> String? {
        guard case .math(let defect, let id?) = failure, defect == .noNumber || defect == .garbled,
            case .read(let sheet) = utterance?.math?.reading
        else { return nil }
        return sheet[id]?.text
    }
}

extension MathWarning {
    /// The cell the warning names; nil for one about the whole frame.
    public var cell: CellID? {
        switch self {
        case .suspiciousCell(let id), .doubt(let id), .scaleMismatch(let id), .dashAsZero(let id),
            .parenthesized(let id), .tie(let id):
            id
        case .approximate, .assumedConvention, .rounded: nil
        }
    }
}
