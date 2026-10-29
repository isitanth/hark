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
