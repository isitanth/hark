import Foundation

// The plan request (M13, b1 §4): the measured plan prompt, the image first, the numbered cells and the words. Kept out
// of `AskPrompt`, whose strings stay byte for byte.

public struct PlanPrompt: Sendable, Equatable {
    /// The measured plan prompt of M14.0 (`docs/acceptance/M14-data/bench/plan-prompt-m14.txt`, SHA-256 d9ebeff2…,
    /// `docs/acceptance/M14.md`): 0.1.0's prompt byte for byte (the frozen `plan-prompt.txt` and the `unit_label`
    /// line), then the result rules and the references line. Edit none of it: a change is a new measurement.
    public static let system = """
        You are Hark's calculation planner. The user framed a region of their screen and spoke a question about it.
        You get the image and every text item read from it, each with an ID such as C12, listed by table row.
        Do not compute the answer yourself: write a formula over the IDs that computes it exactly.
        Rules:
        - The question comes from speech recognition and may contain recognition errors: infer what the user wants.
        - A formula uses only: item IDs, + - * / and parentheses, a postfix %, and SUM(...), AVG(...), MIN(...),
          MAX(...), COUNT(...), ROUND(x, n), ABS(x), ARGMIN(...), ARGMAX(...).
        - Numeric constants only for numbers the user spoke (an 18% tip is 18%, 0.18 or 1.18) and for unit conversions
          (100 for a percent, 1000 g in a kg, 12 months in a year). Write decimals with a point.
        - An ID stands for the number in that item's text, sign included: "−62.50", "-62,50 €" and "(62.50)" are
          negative. Currency symbols, thousands separators and units are handled for you. Use ABS(...) when you need an
          amount as positive.
        - Never copy a number from the image into the formula: refer to it by its ID.
        - COUNT(...) counts the IDs it lists, of any item, with or without a number: for "how many" questions, list the
          IDs of the items that match, each once.
        - An item showing a percent is its number: write C9% to use it as a rate (C3 * C9% is C3 times the rate).
        - A percentage is returned as a percent value, for example (C9 - C5) / C5 * 100.
        - For a question that asks which row is lowest or highest, use ARGMIN or ARGMAX, each argument written
          value @ label, the label being the item that names the row: ARGMIN(C42 / C16 @ C32, C43 / C17 @ C33).
        - "understood": one sentence, in the language of the question, written to the user like "You want the total of
          the paid invoices; the refunded one is left out.": what is computed, which rows count, and any assumption.
          Never name the winner of an ARGMIN or ARGMAX in it, and never a result: Hark computes and names them.
        - "unit": the result's unit: EUR, USD, GBP, percent, count, hours or none. For an amount in any other
          currency (CHF, CAD, JPY...), write none: Hark shows the currency of the items.
        - "unit_label": the word the result's unit is written with in the items the formula reads (To, Go, vCPU, kg…),
          copied as written; empty for money, a percent, hours or a count of rows. Never a number.
        - "results": one entry per figure the user asks for, at most 3, in the order asked. "Two results", "the total of A
          and the total of B", "the average and the maximum" are separate entries; never add or combine them unless the user
          asks for their sum. A question for one figure is one entry.
        - Each entry has its own "understood", "formula", "unit" and "unit_label", and its "understood" names only that
          figure.
        - If the user asks for more than 3 figures, or for one that the items cannot give, write the entries you can and say
          in the last "understood" what was left out.
        - An earlier result is RES1, RES2..., as listed: use its ID when the user names a result (by its number, its position
          or its figure); never copy its number.
        - A question for the row that is lowest or highest and its value is one entry: its ARGMIN or ARGMAX gives both.
          Never add an entry that repeats a figure another entry gives.
        - RES IDs name only the earlier results listed, never an entry of this reply: write each entry's formula from the
          item IDs (a total with a 20% VAT is SUM(...) * 1.20, not the first entry plus the second).
        """

    /// The user turn's first line: longer than 23 characters and holding no user text, so MTPLX's request log, which
    /// keeps the first 23 characters, never holds the words.
    public static let leadLine = "Hark calculation request, spoken question about the framed image:"
    /// A follow-up's first line, for the same reason.
    public static let followUpLeadLine = "Hark calculation follow-up, spoken by the user:"
    /// The line before the listing, as measured (`harness.plan_user_text`).
    public static let itemsLine = "Items read from the image:"

    /// The system message, then the user turns; a follow-up's earlier turns each add their reply as an assistant
    /// message.
    public let messages: [ChatMessage]
    /// Whether the selection was cut to the cap.
    public let truncated: Bool

    public init(
        instruction: String, sheet: CellSheet, image: ImagePart?, selection: String?,
        maxSelectionChars: Int = LLMConfig.defaultMaxSelectionChars
    ) {
        let (lines, truncated) = Self.questionLines(
            lead: Self.leadLine, instruction: instruction, selection: selection, maxSelectionChars: maxSelectionChars)
        self.truncated = truncated
        messages = [
            ChatMessage(role: .system, content: Self.system),
            Self.userMessage(lines + Self.listingLines(sheet), image: image),
        ]
    }

    private init(messages: [ChatMessage], truncated: Bool) {
        self.messages = messages
        self.truncated = truncated
    }

    /// A computational follow-up, planned again over the conversation's latest sheet (plan §4.4). Turn by turn, as
    /// `AskPrompt.thread`: each answered turn's user message is the same bytes on every later turn, then its reply.
    /// An exact turn's reply is the one Hark wrote, with its formula when it read `sheet` ([SETTLED] 12). The listing
    /// goes in the current turn only. Nil when a framed turn's image is missing: nothing is sent then.
    public static func thread(
        _ thread: AskThread, current: (instruction: String, image: ImagePart?), sheet: CellSheet,
        images: [UtteranceID: ImagePart], maxSelectionChars: Int = LLMConfig.defaultMaxSelectionChars
    ) -> PlanPrompt? {
        var messages = [ChatMessage(role: .system, content: system)]
        var truncated = false
        for (index, turn) in thread.turns.enumerated() {
            var image: ImagePart?
            if turn.region != nil {
                guard let frame = images[turn.id] else { return nil }
                image = frame
            }
            let (lines, cut) = turnLines(
                index, instruction: turn.instruction, selection: thread.selection,
                maxSelectionChars: maxSelectionChars)
            if index == 0 { truncated = cut }
            messages.append(userMessage(lines, image: image))
            messages.append(ChatMessage(role: .assistant, content: reply(of: turn, sheet: sheet)))
        }
        let (lines, cut) = turnLines(
            thread.turns.count, instruction: current.instruction, selection: thread.selection,
            maxSelectionChars: maxSelectionChars)
        if thread.turns.isEmpty { truncated = cut }
        messages.append(userMessage(lines + listingLines(sheet), image: current.image))
        return PlanPrompt(messages: messages, truncated: truncated)
    }

    /// The retry (decision 18, b2 §9.5): the same messages, the rejected reply as the model's, then the note that names
    /// its defect. The note is `PlanDefect.correction`: a rule, an ID or a constant, never a cell's text.
    public static func retry(_ prompt: PlanPrompt, correction: PlanCorrection) -> PlanPrompt {
        PlanPrompt(
            messages: prompt.messages + [
                ChatMessage(role: .assistant, content: correction.reply),
                ChatMessage(role: .user, content: retryLine(correction.note)),
            ],
            truncated: prompt.truncated)
    }

    /// The retry's user turn, as measured (`harness.retry_message`).
    public static func retryLine(_ note: String) -> String {
        "Hark could not use that plan: \(note). Reply with a corrected plan."
    }

    /// The numbered cells as the model reads them, in the format that scored 20/20 (`harness.items_from_vision`):
    /// `Table n:`, then `R<row>: C1 "…" | C2 "…"`, then `Other text:` and one `Cn "…"` per line outside every table.
    /// The IDs are the sheet's own. `Cell.table` and `Cell.row` count from 0, as Vision's do; tables are numbered in
    /// order from 1.
    public static func listing(_ sheet: CellSheet) -> String {
        var lines: [String] = []
        let tables = Set(sheet.cells.compactMap(\.table)).sorted()
        for (number, table) in tables.enumerated() {
            lines.append("Table \(number + 1):")
            let cells = sheet.cells.filter { $0.table == table }
            let rows = Set(cells.map { $0.row ?? -1 }).sorted()
            for row in rows {
                let items = cells.filter { ($0.row ?? -1) == row }
                    .sorted { ($0.column ?? 0, $0.id.index) < ($1.column ?? 0, $1.id.index) }
                lines.append("R\(row + 1): " + items.map(item).joined(separator: " | "))
            }
        }
        let others = sheet.cells.filter { $0.table == nil }
        if !others.isEmpty {
            lines.append("Other text:")
            lines += others.map(item)
        }
        return lines.joined(separator: "\n")
    }

    /// `C12 "text"`, the text escaped so it cannot close its quotes or start a line of its own.
    private static func item(_ cell: Cell) -> String {
        let escaped = cell.text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
        return "\(cell.id) \"\(escaped)\""
    }

    /// The empty line, the items line and the listing, as measured.
    private static func listingLines(_ sheet: CellSheet) -> [String] {
        ["", itemsLine, listing(sheet)]
    }

    /// An exact turn's reply is the composed one (the `%%` line, then Hark's answer), with `Formula:` when it read the
    /// current sheet; a free turn's is its reply.
    private static func reply(of turn: AskTurn, sheet: CellSheet) -> String {
        guard let formula = turn.formula, turn.sheet == sheet else { return turn.reply }
        return turn.reply + "\nFormula: " + formula
    }

    /// Turn `index`'s lines: the lead line, the words, and turn 1's selection.
    private static func turnLines(
        _ index: Int, instruction: String, selection: String?, maxSelectionChars: Int
    ) -> ([String], Bool) {
        questionLines(
            lead: index == 0 ? leadLine : followUpLeadLine, instruction: instruction,
            selection: index == 0 ? selection : nil, maxSelectionChars: maxSelectionChars)
    }

    private static func questionLines(
        lead: String, instruction: String, selection: String?, maxSelectionChars: Int
    ) -> ([String], Bool) {
        var lines = [lead, "Question: " + instruction.trimmingCharacters(in: .whitespacesAndNewlines)]
        guard let selection else { return (lines, false) }
        let cap = max(0, maxSelectionChars)
        let truncated = selection.count > cap
        let kept = truncated ? String(selection.prefix(cap)) : selection
        // As `AskPrompt`'s block: literal, so a combining mark after the ">" cannot hide the tag.
        let escaped = kept.replacingOccurrences(
            of: "</selection>", with: "</ selection>", options: [.caseInsensitive, .literal])
        lines += ["<selection>", escaped, "</selection>"]
        if truncated { lines.append("Only the first \(cap) characters of the selection are included.") }
        return (lines, truncated)
    }

    /// The image first, then the text; the text alone is a plain message.
    private static func userMessage(_ lines: [String], image: ImagePart?) -> ChatMessage {
        let text = lines.joined(separator: "\n")
        guard let image else { return ChatMessage(role: .user, content: text) }
        return ChatMessage(role: .user, parts: [.image(image), .text(text)])
    }
}
