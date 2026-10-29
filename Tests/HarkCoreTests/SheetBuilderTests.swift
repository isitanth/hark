import CoreGraphics
import Foundation
import Testing

@testable import HarkCore

/// The test's own copy of harness.items_from_vision's listing (S3 ships `PlanPrompt.listing`).
func harnessListing(_ sheet: CellSheet, tableCount: Int) -> String {
    var lines: [String] = []
    for table in 0..<tableCount {
        lines.append("Table \(table + 1):")
        var row: Int?
        var parts: [String] = []
        for cell in sheet.cells where cell.table == table {
            if cell.row != row, let row {
                lines.append("R\(row + 1): " + parts.joined(separator: " | "))
                parts = []
            }
            row = cell.row
            parts.append("\(cell.id) \"\(cell.text)\"")
        }
        if let row { lines.append("R\(row + 1): " + parts.joined(separator: " | ")) }
    }
    let others = sheet.cells.filter { $0.table == nil }
    if !others.isEmpty {
        lines.append("Other text:")
        lines += others.map { "\($0.id) \"\($0.text)\"" }
    }
    return lines.joined(separator: "\n")
}

@Suite struct SheetBuilderParityTests {
    private func build(_ fixture: ReaderFixture, split: Bool) async -> (SheetBuild, ScriptedCrops) {
        let crops = fixture.scriptedCrops()
        let none: SheetBuilder.AmountSplitter = { _ in [] }
        let result = await SheetBuilder.build(
            fixture.document, options: .frozen, amounts: split ? fixture.splitter : none,
            crop: { crops.read($0, $1) })
        return (result, crops)
    }

    private func tableCount(_ fixture: ReaderFixture, _ sheet: CellSheet) -> Int {
        let tables = fixture.document.tables.count
        return sheet.cells.contains { $0.table == tables } ? tables + 1 : tables
    }

    @Test(arguments: ReaderFixture.cases)
    func theBuilderGivesV2FsCells(name: String) async throws {
        let fixture = try ReaderFixture.load(name)
        let (result, crops) = await build(fixture, split: false)
        #expect(crops.unknown == [])
        let got = result.sheet.cells.map {
            ReaderFixture.ExpectedCell(
                id: $0.id.description, text: $0.text, table: $0.table, row: $0.row, column: $0.column,
                uncertain: $0.suspicious)
        }
        #expect(got.count == fixture.expected.cells.count)
        for (mine, theirs) in zip(got, fixture.expected.cells) where mine != theirs {
            Issue.record("\(name): got \(mine) \(mine.uncertain), want \(theirs) \(theirs.uncertain)")
        }
        #expect(harnessListing(result.sheet, tableCount: tableCount(fixture, result.sheet)) == fixture.expected.listing)
    }

    @Test(arguments: ReaderFixture.cases)
    func everyAmountGetsItsOwnID(name: String) async throws {
        let fixture = try ReaderFixture.load(name)
        let (result, _) = await build(fixture, split: true)
        #expect(
            harnessListing(result.sheet, tableCount: tableCount(fixture, result.sheet))
                == fixture.expected.splitListing)
    }
}

private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 0.1, _ h: CGFloat = 0.02) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

private func cell(_ r: Int, _ c: Int, _ text: String, _ at: CGRect, rs: Int = 1, cs: Int = 1, lines: [RawLine]? = nil)
    -> RawCell
{
    RawCell(
        row: r, column: c, rowSpan: rs, columnSpan: cs, transcript: text, box: at,
        lines: lines ?? (text.isEmpty ? [] : [RawLine(text: text, box: at)]))
}

private let noSplit: SheetBuilder.AmountSplitter = { _ in [] }

@Suite struct SheetBuilderStepTests {
    // R2

    @Test func aTwoLineCellBecomesTwoItems() {
        let lines = [RawLine(text: "Total", box: box(0.1, 0.1)), RawLine(text: "12,00", box: box(0.1, 0.13))]
        let items = SheetBuilder.split(
            [cell(2, 3, "Total\n12,00", box(0.1, 0.1, 0.1, 0.05), lines: lines)], enabled: true)
        #expect(items.map(\.text) == ["Total", "12,00"])
        #expect(items.map(\.box) == lines.map(\.box))
        #expect(items.allSatisfy { $0.row == 2 && $0.column == 3 && $0.split })
    }

    @Test(arguments: [
        ("12,00", 1, true), ("Total\n12,00", 1, true), ("Total\n12,00", 2, false),
    ])
    func aCellStaysWholeUnlessItHasSeveralLines(text: String, lineCount: Int, enabled: Bool) {
        let lines = (0..<lineCount).map { RawLine(text: "x", box: box(0.1, 0.1 + CGFloat($0) * 0.03)) }
        let items = SheetBuilder.split([cell(0, 0, text, box(0.1, 0.1), lines: lines)], enabled: enabled)
        #expect(items.count == 1)
        #expect(items[0].text == text)
    }

    // target_boxes

    @Test func cropBoxesFollowTheLinesOrTheRowsBand() {
        let a = RawLine(text: "12", box: box(0.10, 0.10, 0.05, 0.02))
        let b = RawLine(text: "34", box: box(0.20, 0.12, 0.05, 0.02))
        var items = [
            SheetBuilder.Item(cell: cell(0, 0, "12 34", box(0.05, 0.05, 0.3, 0.1), lines: [a, b])),
            SheetBuilder.Item(cell: cell(0, 1, "", box(0.4, 0.05, 0.1, 0.1))),
            SheetBuilder.Item(cell: cell(1, 1, "", box(0.4, 0.2, 0.1, 0.1))),
            SheetBuilder.Item(cell: cell(2, 0, "9", box(0.1, 0.4), rs: 2)),
            SheetBuilder.Item(cell: cell(2, 1, "", box(0.4, 0.4, 0.1, 0.1))),
        ]
        SheetBuilder.targetBoxes(&items)
        #expect(items[0].crop == SheetBuilder.union([a.box, b.box]))
        #expect(items[1].crop == CGRect(x: 0.4, y: 0.12, width: 0.1, height: (0.12 + 0.02) - 0.12))
        #expect(items[2].crop == items[2].box)
        #expect(items[4].crop == items[4].box)
    }

    // R5

    @Test(arguments: [(49, false), (50, true), (51, true)])
    func aColumnIsNumericFromHalfItsCells(clean: Int, numeric: Bool) {
        let items = (0..<100).map { index in
            SheetBuilder.Item(cell: cell(index, 0, index < clean ? "12,00" : "n/a", box(0.1, 0.1)))
        }
        #expect((SheetBuilder.numericColumns(items)[0] != nil) == numeric)
    }

    @Test func aNumericColumnsDecimalsAreItsMode() {
        let items = ["1,00", "2,5", "3,00", "4,5", "5,00"].enumerated().map {
            SheetBuilder.Item(cell: cell($0.offset, 0, $0.element, box(0.1, 0.1)))
        }
        #expect(SheetBuilder.numericColumns(items)[0] == 2)
    }

    @Test func validationFlagsWhatANumericColumnCannotHold() {
        let texts = ["1,00", "2,00", "3,00", "4,00", "5,00", "Seats", "Seatsą", "", "12,0x", "12,5"]
        var items = texts.enumerated().map { SheetBuilder.Item(cell: cell($0.offset, 0, $0.element, box(0.1, 0.1))) }
        items.append(SheetBuilder.Item(cell: cell(20, 0, "7,5", box(0.1, 0.1), cs: 2)))
        var split = SheetBuilder.Item(cell: cell(21, 0, "8,5", box(0.1, 0.1)))
        split.split = true
        items.append(split)
        let flagged = SheetBuilder.validate(&items)
        #expect(flagged == [6, 7, 8, 9])
        #expect(flagged.map { items[$0].why } == [.garbled, .empty, .garbled, .decimals])
    }

    @Test func aGarbledFreeLineIsFlaggedOutsideTablesOnly() async {
        let document = RawDocument(
            tables: [RawTable(box: box(0, 0, 0.5, 0.5), cells: [])],
            lines: [RawLine(text: "Total 12ł", box: box(0.1, 0.1)), RawLine(text: "Total 13ł", box: box(0.6, 0.6))])
        let result = await SheetBuilder.build(document, amounts: noSplit) { boxes, _ in boxes.map { _ in "" } }
        #expect(result.stats.flagged == 1)
        #expect(result.sheet.cells.map(\.text) == ["Total 13ł"])
        #expect(result.sheet.cells.map(\.suspicious) == [true])
    }
}

/// A numeric column of four clean cells and one more: the one the ladder works on.
private func ladderDocument(_ last: String) -> RawDocument {
    let texts = ["12,00", "13,00", "14,00", "15,00", last]
    return RawDocument(tables: [
        RawTable(
            box: box(0, 0, 0.5, 0.5),
            cells: texts.enumerated().map { cell($0.offset, 0, $0.element, box(0.1, 0.05 + CGFloat($0.offset) * 0.05)) }
        )
    ])
}

@Suite struct SheetBuilderLadderTests {
    private func run(_ last: String, _ reads: [String], options: ReaderOptions = .frozen) async -> (
        SheetBuild, [Rung]
    ) {
        var rungs: [Rung] = []
        let result = await SheetBuilder.build(ladderDocument(last), options: options, amounts: noSplit) { boxes, rung in
            rungs.append(rung)
            return boxes.map { _ in reads.count >= rungs.count ? reads[rungs.count - 1] : "" }
        }
        return (result, rungs)
    }

    @Test func theFirstAcceptedRungWins() async throws {
        let (result, rungs) = await run("16,0ł", ["16,0", "16,00", "99,00"])
        let cell = try #require(result.sheet[CellID(5)])
        #expect(cell.text == "16,00")
        #expect(!cell.suspicious)
        #expect(rungs == Array(Rung.ladder.prefix(2)))
        #expect(result.stats.fixed == [0, 1, 0, 0])
        #expect(result.notes[CellID(5)] == ReadNote(why: .garbled, tries: ["16,0"]))
    }

    @Test(arguments: [
        ("abc", false), ("16,00ł", false), ("16,00 x", false), ("16,0", false), ("17,00", false), ("16,00", true),
        ("16,00 €", true),
    ])
    func aReadIsAcceptedOnlyWhenItValidates(read: String, accepted: Bool) {
        var item = SheetBuilder.Item(cell: cell(4, 0, "16,0ł", box(0.1, 0.1)))
        item.why = .garbled
        item.wantDecimals = 2
        #expect(SheetBuilder.accepts(read, for: item) == accepted)
    }

    @Test func aCellNoRungAcceptsKeepsItsTextAndIsUncertain() async throws {
        let (result, rungs) = await run("16,0ł", ["x", "y", "z", "w"])
        let cell = try #require(result.sheet[CellID(5)])
        #expect(cell.text == "16,0ł")
        #expect(cell.suspicious)
        #expect(rungs == Rung.ladder)
        #expect(result.stats.uncertain == 1)
    }

    @Test(arguments: [(["", "", "", ""], false), (["ab", "", "", ""], true)])
    func anEmptyCellIsUncertainOnlyWhenARungSawSomething(reads: [String], uncertain: Bool) async throws {
        let (result, _) = await run("", reads)
        let cell = try #require(result.sheet[CellID(5)])
        #expect(cell.text == "")
        #expect(cell.suspicious == uncertain)
    }

    @Test func withoutTheFastRungTheLadderStopsAtThree() async {
        var options = ReaderOptions.frozen
        options.fast = false
        let (_, rungs) = await run("16,0ł", [], options: options)
        #expect(rungs == Array(Rung.ladder.prefix(3)))
    }
}

@Suite struct SheetBuilderRowTests {
    private func line(_ text: String, _ x: CGFloat, _ centre: CGFloat, height: CGFloat = 0.02) -> SheetBuilder.Item {
        SheetBuilder.Item(
            line: RawLine(text: text, box: CGRect(x: x, y: centre - height / 2, width: 0.1, height: height)))
    }

    @Test(arguments: [(0.34, 1), (0.349, 1), (0.351, 2), (0.36, 2)])
    func linesJoinWithinAThirdOfTheirHeight(share: CGFloat, rows: Int) {
        let grouped = SheetBuilder.rows([line("a", 0.1, 0.5), line("b", 0.5, 0.5 + share * 0.02)])
        #expect(grouped.count == rows)
    }

    /// Exactly 0.35 of the line height joins: 0.85 − 0.5 is 0.35 × 1 in binary floating point too.
    @Test func theToleranceItselfJoins() {
        #expect(SheetBuilder.rows([line("a", 0.1, 0.5, height: 1), line("b", 0.5, 0.85, height: 1)]).count == 1)
        #expect(SheetBuilder.rows([line("a", 0.1, 0.5, height: 1), line("b", 0.5, 0.86, height: 1)]).count == 2)
    }

    @Test func aChainOfThreeIsOneRow() {
        let rows = SheetBuilder.rows([line("a", 0.1, 0.5), line("b", 0.3, 0.506), line("c", 0.5, 0.512)])
        #expect(rows.map { $0.map(\.text) } == [["a", "b", "c"]])
    }

    @Test func rowsGoTopDownAndItemsLeftToRight() {
        let rows = SheetBuilder.rows([
            line("d", 0.5, 0.8), line("b", 0.5, 0.2), line("a", 0.1, 0.2), line("c", 0.1, 0.8),
        ])
        #expect(rows.map { $0.map(\.text) } == [["a", "b"], ["c", "d"]])
    }

    @Test func singleLinesStayFreeAndNoRowMakesNoTable() async {
        let document = RawDocument(lines: [
            RawLine(text: "Total", box: box(0.1, 0.5)), RawLine(text: "Merci", box: box(0.1, 0.1)),
        ])
        let result = await SheetBuilder.build(document, amounts: noSplit) { boxes, _ in boxes.map { _ in "" } }
        #expect(result.sheet.cells.map(\.text) == ["Merci", "Total"])
        #expect(result.sheet.cells.allSatisfy { $0.table == nil })
    }
}

/// A receipt: three rows, the first two ending in a VAT letter, the third's letter dropped.
private func receipt(letters: [String] = ["A", "B"]) -> RawDocument {
    var lines: [RawLine] = []
    for (row, (label, amount)) in [("Pain", "3,79"), ("Lait", "1,20"), ("Oeufs", "2,50")].enumerated() {
        let y = 0.1 + CGFloat(row) * 0.1
        lines.append(RawLine(text: label, box: box(0.05, y)))
        lines.append(RawLine(text: amount, box: box(0.30, y)))
        if row < letters.count { lines.append(RawLine(text: letters[row], box: box(0.60, y, 0.03))) }
    }
    return RawDocument(lines: lines)
}

@Suite struct SheetBuilderCodeTests {
    private func run(_ document: RawDocument, read: String, options: ReaderOptions = .frozen) async -> (
        SheetBuild, [[CGRect]]
    ) {
        var asked: [[CGRect]] = []
        let result = await SheetBuilder.build(document, options: options, amounts: noSplit) { boxes, rung in
            asked.append(boxes)
            return boxes.map { _ in rung == Rung.ladder[0] ? read : "" }
        }
        return (result, asked)
    }

    @Test func aDroppedCodeLetterIsReadBack() async {
        let (result, asked) = await run(receipt(), read: "2,50 A")
        #expect(asked == [[CGRect(x: 0.30, y: 0.1 + 2 * 0.1, width: (0.60 + 0.03) - 0.30, height: 0.02)]])
        #expect(result.sheet.cells.map(\.text) == ["Pain", "3,79", "A", "Lait", "1,20", "B", "Oeufs", "2,50 A"])
        #expect(result.stats.codes == 1)
    }

    @Test func aReadWithAnotherNumberIsRefused() async {
        let (result, asked) = await run(receipt(), read: "2,51 A")
        #expect(asked.count == Rung.ladder.count)
        #expect(result.sheet.cells.last?.text == "2,50")
    }

    @Test func oneLetterMakesNoCodeColumn() async {
        let (_, asked) = await run(receipt(letters: ["A"]), read: "2,50 A")
        #expect(asked.isEmpty)
    }

    @Test func codeLettersCanBeSwitchedOff() async {
        var options = ReaderOptions.frozen
        options.codeLetters = false
        let (_, asked) = await run(receipt(), read: "2,50 A", options: options)
        #expect(asked.isEmpty)
    }
}

@Suite struct SheetBuilderNumberingTests {
    @Test func cellsAreNumberedTablesFirstThenTextRowsThenFreeLines() async {
        let document = RawDocument(
            tables: [
                RawTable(
                    box: box(0, 0, 0.4, 0.2),
                    cells: [
                        cell(1, 0, "b", box(0.05, 0.1)), cell(0, 1, "a2", box(0.2, 0.05)),
                        cell(
                            0, 0, "a1\na1bis", box(0.05, 0.05, 0.1, 0.04),
                            lines: [
                                RawLine(text: "a1", box: box(0.05, 0.05)), RawLine(text: "a1bis", box: box(0.05, 0.07)),
                            ]),
                    ]),
                RawTable(box: box(0.5, 0, 0.4, 0.2), cells: [cell(0, 0, "t2", box(0.55, 0.05))]),
            ],
            lines: [
                RawLine(text: "inside", box: box(0.05, 0.1)), RawLine(text: "left", box: box(0.05, 0.6)),
                RawLine(text: "right", box: box(0.5, 0.6)), RawLine(text: "alone", box: box(0.05, 0.9)),
            ])
        let result = await SheetBuilder.build(document, amounts: noSplit) { boxes, _ in boxes.map { _ in "" } }
        let cells = result.sheet.cells
        #expect(cells.map(\.text) == ["a1", "a1bis", "a2", "b", "t2", "left", "right", "alone"])
        #expect(cells.map(\.id) == (1...8).map(CellID.init))
        #expect(cells.map(\.table) == [0, 0, 0, 0, 1, 2, 2, nil])
    }

    @Test func anItemWithTwoAmountsGetsTwoIDs() async {
        let text = "5,10 €  4,59 €"
        let splitter: SheetBuilder.AmountSplitter = { item in
            guard item == text else { return [] }
            let first = item.range(of: "5,10 €")!
            let second = item.range(of: "4,59 €")!
            return [first, second]
        }
        let document = RawDocument(lines: [RawLine(text: text, box: box(0.1, 0.1))])
        let result = await SheetBuilder.build(document, amounts: splitter) { boxes, _ in boxes.map { _ in "" } }
        #expect(result.sheet.cells.map(\.text) == ["5,10 €", "4,59 €"])
        #expect(result.sheet.cells.map(\.box) == [box(0.1, 0.1), box(0.1, 0.1)])
    }

    @Test func countsNeverHoldAText() async {
        let document = RawDocument(lines: [RawLine(text: "secret 1 234,56ł", box: box(0.1, 0.1))])
        let result = await SheetBuilder.build(document, amounts: noSplit) { boxes, _ in boxes.map { _ in "secret 9ą" } }
        #expect(result.stats.flagged == 1 && result.stats.uncertain == 1)
        #expect(!result.stats.description.contains("secret"))
        #expect(!result.description.contains("secret"))
        #expect(!result.sheet.description.contains("secret"))
        #expect(!result.sheet.description.contains("234"))
    }

    @Test(arguments: [
        (["−48,90"], "−" as Character, nil as Character?, nil as Character?),
        (["-48,90", "−2,00", "-1,00"], "-", nil, nil),
        (["FA-2026", "12,00"], "-", nil, nil),
        (["10 – 12", "– 3 items", "−4,00"], "−", nil, nil),
        (["12\u{202F}%"], "-", nil, "\u{202F}"),
        (["12%"], "-", nil, nil),
        (["12,50\u{00A0}€", "3,00\u{00A0}€", "4 €"], "-", "\u{00A0}", nil),
        (["12,50€"], "-", nil, nil),
    ])
    func theConventionTakesTheDocumentsMinusAndSpacing(
        texts: [String], minus: Character, currencySpacing: Character?, percentSpacing: Character?
    ) {
        let convention = SheetBuilder.documentConvention(of: texts, base: .plain)
        #expect(convention.minus == minus)
        #expect(convention.currencySpacing == currencySpacing)
        #expect(convention.percentSpacing == percentSpacing)
    }

    @Test func aSheetWithNoPercentKeepsTheDefault() {
        let base = NumberConvention(decimalSeparator: ",", percentSpacing: " ")
        #expect(SheetBuilder.documentConvention(of: ["12,00"], base: base) == base)
    }
}
