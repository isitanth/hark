import CoreGraphics
import Foundation

// The reader's hardening (M13.3), pure: V2F's steps R2 to R8 over what Vision gave, then the numbering. A port of
// run_v2f.py, rows_for_lines.py, glyph_codes.py and harness.items_from_vision, step for step; geometry in Double.

/// The switches the held-out ablation flips (plan §4.2). `.frozen` is V2F as it ran; M13 ships nothing else.
public struct ReaderOptions: Sendable, Equatable {
    /// R2: a cell holding several lines becomes one item per line.
    public var split: Bool
    /// R6's last rung, the fast recognizer.
    public var fast: Bool
    /// R8: the lone code letters beside a receipt's amounts.
    public var codeLetters: Bool
    /// R3: Cyrillic `З`/`О` in a number become `3`/`0`.
    public var homoglyphs: Bool
    /// The longest side the reader gets, in pixels.
    public var inputCap: Int
    /// The document request's scale on native pixels.
    public var docsScale: Double
    /// The Mac's decimal separator, the number parser's last resort. HarkCore reads no locale of its own.
    public var macDecimal: Character

    public init(
        split: Bool = true, fast: Bool = true, codeLetters: Bool = true, homoglyphs: Bool = true,
        inputCap: Int = 4096, docsScale: Double = 1.0, macDecimal: Character = "."
    ) {
        self.split = split
        self.fast = fast
        self.codeLetters = codeLetters
        self.homoglyphs = homoglyphs
        self.inputCap = inputCap
        self.docsScale = docsScale
        self.macDecimal = macDecimal
    }

    public static let frozen = ReaderOptions()
}

/// Why a cell was sent to the ladder.
public enum ReadDefect: String, Sendable, Equatable {
    case empty
    case garbled
    case decimals
}

/// Counts only, never a text: what the ladder did.
public struct ReaderStats: Sendable, Equatable, CustomStringConvertible {
    /// Cells and lines sent to the ladder.
    public var flagged = 0
    /// Fixed per rung of `Rung.ladder`.
    public var fixed = [Int](repeating: 0, count: Rung.ladder.count)
    /// Code letters recovered (R8).
    public var codes = 0
    public var uncertain = 0

    public init() {}

    public var description: String {
        "ReaderStats(flagged \(flagged), fixed \(fixed.map(String.init).joined(separator: "/")), codes \(codes), "
            + "uncertain \(uncertain))"
    }
}

/// What the ladder made of one item, for the tests: never logged.
public struct ReadNote: Sendable, Equatable {
    public var why: ReadDefect?
    /// One rejected read per rung tried.
    public var tries: [String]
}

/// The sheet, its counts, and per item why it was re-read.
public struct SheetBuild: Sendable, CustomStringConvertible {
    public let sheet: CellSheet
    public let stats: ReaderStats
    public let notes: [CellID: ReadNote]

    public var description: String { "SheetBuild(\(sheet), \(stats))" }
}

public enum SheetBuilder {
    /// One item on its way to the sheet: a table cell, a part of a split one, or a free line.
    struct Item {
        var text: String
        var docsText: String
        var box: CGRect
        var crop: CGRect
        var lines: [RawLine]
        var row: Int
        var column: Int
        var rowSpan = 1
        var columnSpan = 1
        var split = false
        var why: ReadDefect?
        var wantDecimals: Int?
        var tries: [String] = []
        var flagged = false
        /// A rung's read was accepted.
        var fixed = false

        init(cell: RawCell) {
            text = cell.transcript
            docsText = cell.transcript
            box = cell.box
            crop = cell.box
            lines = cell.lines
            row = cell.row
            column = cell.column
            rowSpan = cell.rowSpan
            columnSpan = cell.columnSpan
        }

        init(line: RawLine) {
            text = line.text
            docsText = line.text
            box = line.box
            crop = line.box
            lines = []
            row = 0
            column = 0
        }

        /// Still unread after the last rung, unless every rung saw an empty cell empty.
        var uncertain: Bool {
            guard flagged, !fixed else { return false }
            return why != .empty || tries.contains { !trimmed($0).isEmpty }
        }
    }

    /// A table on its way: the document's, or the text rows (R7) with a zero box.
    struct Table {
        var box: CGRect
        var items: [Item]
        var textRows = false
    }

    /// Where an item sits in the work lists: a table's item or a free line.
    enum Ref: Hashable {
        case cell(table: Int, item: Int)
        case line(Int)
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// R2 to R5: items, crop boxes, homoglyphs, validation.
extension SheetBuilder {
    /// R2: a cell whose text holds a `\n` and that has more than one line becomes one item per line.
    static func split(_ cells: [RawCell], enabled: Bool) -> [Item] {
        cells.flatMap { cell -> [Item] in
            guard enabled, cell.transcript.contains("\n"), cell.lines.count > 1 else { return [Item(cell: cell)] }
            return cell.lines.map { line in
                var item = Item(cell: cell)
                item.text = line.text
                item.docsText = line.text
                item.box = line.box
                item.crop = line.box
                item.lines = [line]
                item.split = true
                return item
            }
        }
    }

    /// `target_boxes`: a cell with text is cropped to the union of its lines; an empty one to its own x-span times
    /// the median top and bottom of its row's lines; one in a row with no lines keeps its box.
    static func targetBoxes(_ items: inout [Item]) {
        var band: [Int: [CGRect]] = [:]
        for item in items where item.rowSpan == 1 {
            band[item.row, default: []].append(contentsOf: item.lines.map(\.box))
        }
        for index in items.indices {
            let item = items[index]
            if !item.lines.isEmpty {
                items[index].crop = union(item.lines.map(\.box))
            } else if let boxes = band[item.row], !boxes.isEmpty {
                let tops = boxes.map(\.origin.y).sorted()
                let bottoms = boxes.map { $0.origin.y + $0.size.height }.sorted()
                let top = tops[tops.count / 2]
                let bottom = bottoms[bottoms.count / 2]
                items[index].crop = CGRect(
                    x: item.box.origin.x, y: top, width: item.box.size.width, height: bottom - top)
            } else {
                items[index].crop = item.box
            }
        }
    }

    /// The prototype's union, `[x0, y0, x1 - x0, y1 - y0]`, in the same order of operations.
    static func union(_ boxes: [CGRect]) -> CGRect {
        let x0 = boxes.map(\.origin.x).min() ?? 0
        let y0 = boxes.map(\.origin.y).min() ?? 0
        let x1 = boxes.map { $0.origin.x + $0.size.width }.max() ?? 0
        let y1 = boxes.map { $0.origin.y + $0.size.height }.max() ?? 0
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// R3: the text, with `З`/`О` read as digits.
    static func homoglyphs(_ items: inout [Item], enabled: Bool) {
        guard enabled else { return }
        for index in items.indices {
            items[index].text = ReaderVocabulary.replacingHomoglyphs(items[index].text)
        }
    }

    /// The columns where at least half the non-empty single cells are clean numbers, with their usual decimals.
    static func numericColumns(_ items: [Item]) -> [Int: Int] {
        var votes: [Int: [Bool]] = [:]
        for item in items where !trimmed(item.text).isEmpty && item.rowSpan == 1 && item.columnSpan == 1 {
            votes[item.column, default: []].append(ReaderVocabulary.isClean(item.text))
        }
        var columns: [Int: Int] = [:]
        for (column, clean) in votes
        where Double(clean.filter { $0 }.count) >= Double(ReaderVocabulary.numericShare) * Double(clean.count) {
            let shown = items.filter { $0.column == column && ReaderVocabulary.isClean($0.text) }
                .map { ReaderVocabulary.decimals($0.text) }
            columns[column] = mode(shown) ?? 0
        }
        return columns
    }

    /// The most common value, the first seen on a tie (Python's `Counter.most_common`).
    static func mode<T: Hashable>(_ values: [T]) -> T? {
        var counts: [T: Int] = [:]
        var order: [T] = []
        for value in values {
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
        var best: T?
        for value in order where best.map({ counts[value]! > counts[$0]! }) ?? true {
            best = value
        }
        return best
    }

    /// R5 over one table: flags the cells to re-read, in order.
    static func validate(_ items: inout [Item]) -> [Int] {
        let numeric = numericColumns(items)
        var flagged: [Int] = []
        for index in items.indices {
            let item = items[index]
            let inNumeric =
                numeric[item.column] != nil && item.rowSpan == 1 && item.columnSpan == 1 && !item.split
            items[index].wantDecimals = inNumeric ? numeric[item.column] : nil
            let text = item.text
            if inNumeric, ReaderVocabulary.hasWord(text), !ReaderVocabulary.isSuspicious(text) {
                continue  // a header or a label in a numeric column ("Seats", "Mon 19")
            } else if inNumeric {
                if trimmed(text).isEmpty {
                    items[index].why = .empty
                } else if !ReaderVocabulary.isClean(text) {
                    items[index].why = .garbled
                } else if ReaderVocabulary.decimals(text) != numeric[item.column] {
                    items[index].why = .decimals
                } else {
                    continue
                }
                flagged.append(index)
            } else if ReaderVocabulary.hasDigit(text), ReaderVocabulary.isSuspicious(text) {
                items[index].why = .garbled
                flagged.append(index)
            }
        }
        return flagged
    }

    /// Whether a box's centre lies in one of the areas, edges included.
    static func inside(_ box: CGRect, _ areas: [CGRect]) -> Bool {
        let cx = box.origin.x + box.size.width / 2
        let cy = box.origin.y + box.size.height / 2
        return areas.contains {
            $0.origin.x <= cx && cx <= $0.origin.x + $0.size.width && $0.origin.y <= cy
                && cy <= $0.origin.y + $0.size.height
        }
    }
}

// R6: the ladder.
extension SheetBuilder {
    /// Whether a rung's read replaces the item's text.
    static func accepts(_ read: String, for item: Item) -> Bool {
        guard !trimmed(read).isEmpty, !ReaderVocabulary.isSuspicious(read), ReaderVocabulary.hasDigit(read) else {
            return false
        }
        let numeric = item.why == .empty || item.why == .decimals || item.wantDecimals != nil
        if numeric {
            guard ReaderVocabulary.isClean(read) else { return false }
            if let want = item.wantDecimals, ReaderVocabulary.decimals(read) != want { return false }
        }
        let prefix = ReaderVocabulary.cleanPrefix(ReaderVocabulary.replacingHomoglyphs(item.docsText))
        return ReaderVocabulary.digits(read).hasPrefix(prefix)
    }

    /// Re-reads the flagged items rung by rung, each rung's crops in one batch, until every one is accepted.
    static func ladder(
        _ tables: inout [Table], _ lines: inout [Item], todo start: [Ref], options: ReaderOptions,
        stats: inout ReaderStats, crop: (_ boxes: [CGRect], _ rung: Rung) async -> [String]
    ) async {
        var todo = start
        for (rungIndex, rung) in Rung.ladder.enumerated() {
            guard !todo.isEmpty, !Task.isCancelled else { break }
            if rung.level == .fast, !options.fast { continue }
            let reads = await crop(todo.map { item(at: $0, tables, lines).crop }, rung)
            var left: [Ref] = []
            for (offset, ref) in todo.enumerated() {
                let raw = offset < reads.count ? reads[offset] : ""
                let read = options.homoglyphs ? ReaderVocabulary.replacingHomoglyphs(raw) : raw
                let current = item(at: ref, tables, lines)
                if accepts(read, for: current) {
                    stats.fixed[rungIndex] += 1
                    update(ref, &tables, &lines) {
                        $0.text = read
                        $0.fixed = true
                    }
                } else {
                    update(ref, &tables, &lines) { $0.tries.append(read) }
                    left.append(ref)
                }
            }
            todo = left
        }
    }

    static func item(at ref: Ref, _ tables: [Table], _ lines: [Item]) -> Item {
        switch ref {
        case .cell(let table, let index): tables[table].items[index]
        case .line(let index): lines[index]
        }
    }

    static func update(_ ref: Ref, _ tables: inout [Table], _ lines: inout [Item], _ change: (inout Item) -> Void) {
        switch ref {
        case .cell(let table, let index): change(&tables[table].items[index])
        case .line(let index): change(&lines[index])
        }
    }
}

// R7 and R8: the free lines grouped into rows, and the code letters beside a receipt's amounts.
extension SheetBuilder {
    /// R7: free lines whose centres lie within 0.35 of the smaller line height join one row (transitively). Rows
    /// sorted by their highest centre, items left to right.
    static func rows(_ lines: [Item]) -> [[Item]] {
        var parent = Array(lines.indices)
        func find(_ start: Int) -> Int {
            var index = start
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        let centres = lines.map { $0.box.origin.y + $0.box.size.height / 2 }
        let heights = lines.map { line -> CGFloat in
            line.box.size.height / CGFloat(line.text.filter { $0 == "\n" }.count + 1)
        }
        for i in lines.indices {
            for j in lines.indices
            where j > i && abs(centres[i] - centres[j]) <= ReaderVocabulary.rowTolerance * min(heights[i], heights[j]) {
                let root = find(i)
                parent[root] = find(j)
            }
        }
        var groups: [Int: [Int]] = [:]
        var order: [Int] = []
        for i in lines.indices {
            let root = find(i)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(i)
        }
        let rows = order.map { root in
            stableSorted(groups[root]!.map { lines[$0] }) { $0.box.origin.x < $1.box.origin.x }
        }
        return stableSorted(rows) { top($0) < top($1) }
    }

    private static func top(_ row: [Item]) -> CGFloat {
        row.map { $0.box.origin.y + $0.box.size.height / 2 }.min() ?? 0
    }

    static func stableSorted<T>(_ values: [T], by less: (T, T) -> Bool) -> [T] {
        values.enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// R8 over the text-rows table: a code column exists when 2 rows or more end with a lone capital; a row whose
    /// number ends left of it is re-read up to the column, and takes the read that is the same number and a letter.
    static func codeLetters(
        _ table: inout Table, options: ReaderOptions, stats: inout ReaderStats,
        crop: (_ boxes: [CGRect], _ rung: Rung) async -> [String]
    ) async {
        var lastOfRow: [Int: Int] = [:]
        var rowOrder: [Int] = []
        for (index, item) in table.items.enumerated() {
            guard let last = lastOfRow[item.row] else {
                lastOfRow[item.row] = index
                rowOrder.append(item.row)
                continue
            }
            if item.box.origin.x > table.items[last].box.origin.x { lastOfRow[item.row] = index }
        }
        let lasts = rowOrder.map { lastOfRow[$0]! }
        let glyphs = lasts.filter { ReaderVocabulary.isCodeLetter(table.items[$0].text) }
        guard glyphs.count >= ReaderVocabulary.codeRows else { return }
        let gx0 = glyphs.map { table.items[$0].box.origin.x }.min()!
        let gx1 = glyphs.map { table.items[$0].box.origin.x + table.items[$0].box.size.width }.max()!
        var todo = lasts.filter {
            let item = table.items[$0]
            return ReaderVocabulary.isClean(item.text) && item.box.origin.x + item.box.size.width < gx0
        }
        for rung in Rung.ladder {
            guard !todo.isEmpty, !Task.isCancelled else { break }
            if rung.level == .fast, !options.fast { continue }
            let boxes = todo.map { index -> CGRect in
                let box = table.items[index].box
                return CGRect(x: box.origin.x, y: box.origin.y, width: gx1 - box.origin.x, height: box.size.height)
            }
            let reads = await crop(boxes, rung)
            var left: [Int] = []
            for (offset, index) in todo.enumerated() {
                let read = offset < reads.count ? reads[offset] : ""
                if let number = ReaderVocabulary.numberAndCode(read),
                    ReaderVocabulary.frenchNumber(number) == ReaderVocabulary.frenchNumber(table.items[index].text)
                {
                    table.items[index].text = trimmed(read)
                    stats.codes += 1
                } else {
                    left.append(index)
                }
            }
            todo = left
        }
    }
}

// The whole build, and the numbering (harness.items_from_vision, plan §4.1: one ID, one number).
extension SheetBuilder {
    /// The amounts in a text, what the numbering splits on: S1's parser in the app.
    public typealias AmountSplitter = @Sendable (String) -> [Range<String.Index>]

    public static func build(
        _ document: RawDocument, options: ReaderOptions = .frozen,
        amounts: AmountSplitter = { DisplayedNumber.amounts(in: $0) },
        crop: (_ boxes: [CGRect], _ rung: Rung) async -> [String]
    ) async -> SheetBuild {
        var stats = ReaderStats()
        var tables = document.tables.map { Table(box: $0.box, items: split($0.cells, enabled: options.split)) }
        var todo: [Ref] = []
        for t in tables.indices {
            targetBoxes(&tables[t].items)
            homoglyphs(&tables[t].items, enabled: options.homoglyphs)
            todo += validate(&tables[t].items).map { Ref.cell(table: t, item: $0) }
        }
        let tableBoxes = tables.map(\.box)
        var lines = document.lines.map(Item.init(line:))
        homoglyphs(&lines, enabled: options.homoglyphs)
        for index in lines.indices where !inside(lines[index].box, tableBoxes) {
            let text = lines[index].text
            if ReaderVocabulary.hasDigit(text), ReaderVocabulary.isSuspicious(text) {
                lines[index].why = .garbled
                todo.append(.line(index))
            }
        }
        for ref in todo { update(ref, &tables, &lines) { $0.flagged = true } }
        stats.flagged = todo.count
        await ladder(&tables, &lines, todo: todo, options: options, stats: &stats, crop: crop)

        let free = lines.filter { !inside($0.box, tableBoxes) }
        let grouped = rows(free)
        let multi = grouped.filter { $0.count >= 2 }
        let singles = grouped.filter { $0.count < 2 }.flatMap { $0 }
        if !multi.isEmpty {
            var items: [Item] = []
            for (r, row) in multi.enumerated() {
                for (c, line) in row.enumerated() {
                    var item = line
                    item.row = r
                    item.column = c
                    item.rowSpan = 1
                    item.columnSpan = 1
                    item.split = false
                    items.append(item)
                }
            }
            var textRows = Table(box: .zero, items: items, textRows: true)
            if options.codeLetters {
                await codeLetters(&textRows, options: options, stats: &stats, crop: crop)
            }
            tables.append(textRows)
        }
        return number(tables: tables, free: singles, options: options, amounts: amounts, stats: stats)
    }

    /// Splits a text on its amounts: one part per amount, each with the words before it. One amount or none: as is.
    static func parts(_ text: String, amounts: AmountSplitter) -> [String] {
        let spans = amounts(text)
        guard spans.count >= 2 else { return [text] }
        var cuts = [text.startIndex] + spans.dropLast().map(\.upperBound)
        cuts.append(text.endIndex)
        return zip(cuts, cuts.dropFirst()).compactMap { start, end -> String? in
            guard start <= end else { return nil }
            let collapsed = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return collapsed.isEmpty ? nil : collapsed
        }
    }

    struct Numbered {
        var text: String
        var box: CGRect
        var table: Int?
        var row: Int?
        var column: Int?
        var uncertain: Bool
        var note: ReadNote?
        var numericColumn: Bool
    }

    static func number(
        tables: [Table], free: [Item], options: ReaderOptions, amounts: AmountSplitter, stats: ReaderStats
    ) -> SheetBuild {
        var numbered: [Numbered] = []
        for (t, table) in tables.enumerated() {
            let sorted = stableSorted(table.items) { ($0.row, $0.column) < ($1.row, $1.column) }
            for item in sorted {
                for text in parts(item.text, amounts: amounts) {
                    numbered.append(
                        Numbered(
                            text: text, box: item.box, table: t, row: item.row, column: item.column,
                            uncertain: item.uncertain, note: note(item), numericColumn: item.wantDecimals != nil))
                }
            }
        }
        for item in free {
            for text in parts(item.text, amounts: amounts) {
                numbered.append(
                    Numbered(
                        text: text, box: item.box, table: nil, row: nil, column: nil, uncertain: item.uncertain,
                        note: note(item), numericColumn: false))
            }
        }
        var final = stats
        final.uncertain = (tables.flatMap(\.items) + free).filter(\.uncertain).count
        let region = documentConvention(
            of: numbered.map(\.text),
            base: DisplayedNumber.convention(
                of: numbered.map { ColumnText(text: $0.text, table: $0.table, column: $0.column) }))
        let columns = columnFacts(numbered)
        var notes: [CellID: ReadNote] = [:]
        var cells: [Cell] = []
        for (offset, entry) in numbered.enumerated() {
            let id = CellID(offset + 1)
            if let note = entry.note { notes[id] = note }
            let facts = entry.table.flatMap { t in entry.column.flatMap { columns[ColumnKey(table: t, column: $0)] } }
            let context = ReadingContext(
                columnDecimal: facts?.decimal, region: region, inTable: entry.table != nil,
                columnHoldsAmounts: entry.numericColumn, columnSigned: facts?.signed ?? false,
                macDecimal: options.macDecimal)
            cells.append(
                Cell(
                    id: id, text: entry.text, reading: DisplayedNumber.read(entry.text, context: context),
                    box: entry.box, table: entry.table, row: entry.row, column: entry.column,
                    suspicious: entry.uncertain))
        }
        return SheetBuild(sheet: CellSheet(cells: cells, convention: region, readMs: 0), stats: final, notes: notes)
    }

    static func note(_ item: Item) -> ReadNote? {
        item.flagged ? ReadNote(why: item.why, tries: item.tries) : nil
    }
}

// What the document says of its own numbers: the column facts the parser needs, the minus and the spacings.
extension SheetBuilder {
    struct ColumnKey: Hashable {
        var table: Int
        var column: Int
    }

    struct ColumnFacts {
        /// The decimal separator its numbers with decimals agree on.
        var decimal: Character?
        var signed = false
    }

    private static let signs: Set<Character> = ["+", "-", "−", "–"]

    static func columnFacts(_ entries: [Numbered]) -> [ColumnKey: ColumnFacts] {
        var separators: [ColumnKey: Set<Character>] = [:]
        var facts: [ColumnKey: ColumnFacts] = [:]
        for entry in entries {
            guard let table = entry.table, let column = entry.column else { continue }
            let key = ColumnKey(table: table, column: column)
            var fact = facts[key] ?? ColumnFacts()
            if let first = trimmed(entry.text).first, signs.contains(first) { fact.signed = true }
            facts[key] = fact
            if ReaderVocabulary.isClean(entry.text), let separator = decimalSeparator(entry.text) {
                separators[key, default: []].insert(separator)
            }
        }
        for (key, found) in separators where found.count == 1 {
            facts[key]?.decimal = found.first
        }
        return facts
    }

    /// The `.` or `,` before a clean number's decimals.
    static func decimalSeparator(_ text: String) -> Character? {
        let range = NSRange(text.startIndex..., in: text)
        guard ReaderVocabulary.decimals(text) > 0,
            let match = ReaderVocabulary.decimalsTail.firstMatch(in: text, range: range),
            let whole = Range(match.range, in: text)
        else { return nil }
        return text[whole].first
    }

    /// A sign attached to its number: an en dash with a space after it is a range or a bullet, not a minus.
    private static let minusForm = ReaderVocabulary.regex(#"(?:^|[\s(])([-−–])[€$£]?\d"#)
    private static let currencyForm = ReaderVocabulary.regex(#"\d([   ]?)(?:[€$£]|EUR\b|USD\b|GBP\b)"#)
    private static let percentForm = ReaderVocabulary.regex(#"\d([   ]?)%"#)

    /// The parser's vote, with the minus and the spacings the document's own numbers use: each the most common form
    /// among the items that show one, the base's when none does.
    static func documentConvention(of texts: [String], base: NumberConvention) -> NumberConvention {
        var convention = base
        if let minus = mode(texts.flatMap { forms(minusForm, $0) }).flatMap({ $0 }) {
            convention.minus = minus
        }
        if let spacing = mode(texts.flatMap { forms(currencyForm, $0) }) {
            convention.currencySpacing = spacing
        }
        if let spacing = mode(texts.flatMap { forms(percentForm, $0) }) {
            convention.percentSpacing = spacing
        }
        return convention
    }

    /// Group 1 of every match: the character, or nil for an empty group.
    private static func forms(_ regex: NSRegularExpression, _ text: String) -> [Character?] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            Range(match.range(at: 1), in: text).flatMap { text[$0].first }
        }
    }
}
