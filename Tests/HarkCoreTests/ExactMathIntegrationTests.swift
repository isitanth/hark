import CoreGraphics
import Foundation
import Testing

@testable import HarkCore

/// Wave 1 together (M13): the reader's sheet with the real splitter and number parser, and the model's listing of it.
@Suite struct ExactMathIntegrationTests {
    /// Every re-read comes back blank: the cells keep the document's text.
    private static func blank(_ boxes: [CGRect], _ rung: Rung) async -> [String] {
        boxes.map { _ in "" }
    }

    private func build(_ fixture: ReaderFixture, amounts: SheetBuilder.AmountSplitter? = nil) async -> CellSheet {
        let crops = fixture.scriptedCrops()
        guard let amounts else {
            return await SheetBuilder.build(fixture.document, options: .frozen) { crops.read($0, $1) }.sheet
        }
        return await SheetBuilder.build(fixture.document, options: .frozen, amounts: amounts) { crops.read($0, $1) }
            .sheet
    }

    private func amount(_ cell: Cell?) -> Amount? {
        guard case .amount(let amount) = cell?.reading else { return nil }
        return amount
    }

    /// The model reads the measured format: S3's listing of S2's sheet is the recorded one, before the split.
    @Test(arguments: ReaderFixture.cases)
    func thePlanListingIsTheMeasuredOne(name: String) async throws {
        let fixture = try ReaderFixture.load(name)
        let sheet = await build(fixture, amounts: { _ in [] })
        #expect(PlanPrompt.listing(sheet) == fixture.expected.listing)
    }

    /// One ID, one number ([SETTLED] 20): with S1's real splitter the listing is the frozen harness's, split by
    /// `harness.split_amounts`, on every recorded case.
    @Test(arguments: ReaderFixture.cases)
    func theRealSplitterGivesTheHarnessListing(name: String) async throws {
        let fixture = try ReaderFixture.load(name)
        let sheet = await build(fixture)
        #expect(PlanPrompt.listing(sheet) == fixture.expected.splitListing)
    }

    /// [SETTLED] 20: c21's misread struck price beside the current one, and c12's "Was" price, are two IDs each.
    @Test func twoAmountsInOneCellAreTwoIDs() async throws {
        let row = CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.05)
        let price = CGRect(x: 0.5, y: 0.4, width: 0.3, height: 0.05)
        let c21 = RawDocument(tables: [
            RawTable(
                box: CGRect(x: 0, y: 0, width: 1, height: 1),
                cells: [
                    RawCell(
                        row: 0, column: 0, rowSpan: 1, columnSpan: 1, transcript: "400 g", box: row,
                        lines: [RawLine(text: "400 g", box: row)]),
                    RawCell(
                        row: 0, column: 1, rowSpan: 1, columnSpan: 1, transcript: "5,10 € 4,59 €", box: price,
                        lines: [RawLine(text: "5,10 € 4,59 €", box: price)]),
                ])
        ])
        let sheet = await SheetBuilder.build(c21, options: .frozen, crop: Self.blank).sheet
        #expect(sheet.cells.map(\.text) == ["400 g", "5,10 €", "4,59 €"])
        #expect(amount(sheet[CellID(2)])?.value == Decimal(string: "5.10"))
        #expect(amount(sheet[CellID(3)])?.value == Decimal(string: "4.59"))
        #expect(amount(sheet[CellID(3)])?.unit == .money(.eur))

        let c12 = await build(try ReaderFixture.load("c12-grocery-en-unitprice"))
        let now = try #require(c12.cells.first { $0.text == "£2.69" })
        let was = try #require(c12.cells.first { $0.text == "Was £2.99" })
        #expect(was.id.index == now.id.index + 1)
        #expect(amount(now)?.value == Decimal(string: "2.69"))
        #expect(amount(was)?.value == Decimal(string: "2.99"))
    }

    /// The kickoff's rows for a lone "1,234" (override 19), on recorded cases: c16's `£18,450` is 18450 (the pound's
    /// minor units), c08's `1,236 kg` beside `2,49` is 1.236 (the receipt's own decimal comma).
    @Test func theRecordedCasesReadTheirAmbiguousAmounts() async throws {
        let c16 = await build(try ReaderFixture.load("c16-sheet-en-growth"))
        let pounds = try #require(c16.cells.first { $0.text == "£18,450" })
        #expect(amount(pounds)?.value == 18450)
        #expect(amount(pounds)?.unit == .money(.gbp))
        #expect(c16.convention.decimalSeparator == ".")

        let c08 = await build(try ReaderFixture.load("c08-receipt-fr-tva20"))
        let weight = try #require(c08.cells.first { $0.text.hasPrefix("1,236") })
        #expect(amount(weight)?.value == Decimal(string: "1.236"))
        #expect(c08.convention.decimalSeparator == ",")
    }

    /// The region decides only when its unambiguous numbers voted (b2 §3.4 step 4). With none and no currency, the
    /// Mac's separator decides, and the reading says it was assumed.
    @Test(arguments: [(",", "1.234"), (".", "1234")] as [(Character, String)])
    func anUndecidedRegionFallsToTheMac(mac: Character, value: String) async throws {
        let document = RawDocument(lines: [
            RawLine(text: "1,234", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)),
            RawLine(text: "2,480", box: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.05)),
        ])
        var options = ReaderOptions.frozen
        options.macDecimal = mac
        let sheet = await SheetBuilder.build(document, options: options, crop: Self.blank).sheet
        let first = try #require(amount(sheet.cells.first { $0.text == "1,234" }))
        #expect(first.value == Decimal(string: value))
        #expect(first.notes.contains(.assumedConvention))
    }

    /// Numbers whose grouping settles itself vote too: beside `1,234,567`, `18,450` is 18450 on any Mac.
    @Test func aSettledGroupingVotesForThePoint() async throws {
        let document = RawDocument(lines: [
            RawLine(text: "1,234,567", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)),
            RawLine(text: "2,345,678", box: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.05)),
            RawLine(text: "18,450", box: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.05)),
        ])
        var options = ReaderOptions.frozen
        options.macDecimal = ","
        let sheet = await SheetBuilder.build(document, options: options, crop: Self.blank).sheet
        #expect(try #require(amount(sheet.cells.first { $0.text == "18,450" })).value == 18450)
    }

    /// A dot grouping votes for the comma, and the region decides with the very separator that voted: beside
    /// `1.234.567`, `18,450` is 18.45, whatever the Mac says.
    @Test func theRegionDecidesWithTheSeparatorItVoted() async throws {
        let document = RawDocument(lines: [
            RawLine(text: "1.234.567", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)),
            RawLine(text: "18,450", box: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.05)),
        ])
        var options = ReaderOptions.frozen
        options.macDecimal = "."
        let sheet = await SheetBuilder.build(document, options: options, crop: Self.blank).sheet
        #expect(sheet.convention.decimalSeparator == ",")
        #expect(try #require(amount(sheet.cells.first { $0.text == "18,450" })).value == Decimal(string: "18.45"))
    }

    /// In a receipt's lines (the text-rows table) a place in the line is no column: a minus in one line does not make
    /// the bracketed number at the same place in another line negative.
    @Test func aReceiptLinesPlaceIsNoColumn() async throws {
        let document = RawDocument(lines: [
            RawLine(text: "Remise", box: CGRect(x: 0.05, y: 0.1, width: 0.2, height: 0.04)),
            RawLine(text: "-1,00", box: CGRect(x: 0.6, y: 0.1, width: 0.1, height: 0.04)),
            RawLine(text: "Pommes", box: CGRect(x: 0.05, y: 0.3, width: 0.2, height: 0.04)),
            RawLine(text: "(3)", box: CGRect(x: 0.6, y: 0.3, width: 0.1, height: 0.04)),
        ])
        let sheet = await SheetBuilder.build(document, options: .frozen, crop: Self.blank).sheet
        let bracketed = try #require(sheet.cells.first { $0.text == "(3)" })
        #expect(bracketed.table != nil && bracketed.column == 1)
        #expect(try #require(amount(bracketed)).value == 3)
    }

    /// A region that writes euros reads an ambiguous lone amount with the euro's decimal comma (step 5), not with the
    /// default a region with no vote would carry.
    @Test func aRegionsCurrencyDecidesAnAmbiguousPrice() async throws {
        let document = RawDocument(lines: [
            RawLine(text: "1,859 €/L", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05))
        ])
        let sheet = await SheetBuilder.build(document, options: .frozen, crop: Self.blank).sheet
        let price = try #require(amount(sheet.cells.first))
        #expect(price.value == Decimal(string: "1.859"))
    }
}
