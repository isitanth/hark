import CoreGraphics
import Foundation
import HarkCore
import Testing

/// Tests/HarkCoreTests/Fixtures/MathGolden: the M13.0 cases' fictional grids and recorded plans, with the frozen
/// Python engine's outcomes, written once by the harness offline (no model call). The word check's tables are copied
/// from `docs/acceptance/M13-data/bench`, frozen with their SHA-256 in `docs/acceptance/M13.md`.
enum MathFixtures {
    static func data(_ name: String) throws -> Data {
        let directory = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try Data(contentsOf: directory.appending(path: "MathGolden").appending(path: name))
    }

    static func text(_ name: String) throws -> String {
        try #require(String(data: try data(name), encoding: .utf8))
    }

    struct Item: Decodable, Sendable {
        let id: String
        let text: String
        let table: Int?
        let row: Int?
        let column: Int?
    }

    /// What the frozen engine made of a reply: a b2 §11 code, or a value and its unit (`M:EUR`, `P`, `H`, `k`, `n`).
    struct Outcome: Decodable, Sendable {
        let defect: String?
        let value: String?
        let unit: String?
        let winner: String?
    }

    struct Expected: Decodable, Sendable {
        let value: String
        let kind: String
    }

    struct GoldenCase: Decodable, Sendable, CustomTestStringConvertible {
        let id: String
        let question: String
        let lang: String
        let expected: Expected
        let grid: [Item]
        let exact: String
        let exactPython: Outcome
        let vision: [Item]
        let plain: String
        let plainPython: Outcome

        var testDescription: String { id }
    }

    struct ParityRow: Decodable, Sendable {
        let reply: String
        let python: Outcome
    }

    struct ParityCase: Decodable, Sendable, CustomTestStringConvertible {
        let id: String
        let question: String
        let lang: String
        let items: [Item]
        let rows: [ParityRow]

        var testDescription: String { id }
    }

    struct SplitRow: Decodable, Sendable, CustomTestStringConvertible {
        let text: String
        let parts: [String]

        var testDescription: String { text }
    }

    static func decode<T: Decodable>(_ name: String) -> T? {
        guard let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil),
            let data = try? Data(contentsOf: directory.appending(path: "MathGolden").appending(path: name))
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static let golden: [GoldenCase] = decode("golden.json") ?? []
    static let parity: [ParityCase] = decode("parity.json") ?? []
    static let split: [SplitRow] = decode("split.json") ?? []

    /// A sheet as a builder would make it: the region's vote, then each cell read in its column's context.
    static func sheet(_ items: [Item], macDecimal: Character = ".") -> CellSheet {
        let convention = DisplayedNumber.convention(
            of: items.map { ColumnText(text: $0.text, table: $0.table, column: $0.column) })
        var columns: [String: [Item]] = [:]
        for item in items {
            guard let table = item.table, let column = item.column else { continue }
            columns["\(table).\(column)", default: []].append(item)
        }
        let currencies = Set(
            items.compactMap { item -> String? in
                guard case .amount(let amount) = DisplayedNumber.read(item.text, context: ReadingContext()),
                    case .money(let currency) = amount.unit
                else { return nil }
                return currency.code
            })
        let regionCurrency = currencies.count == 1 ? currencies.first.flatMap(Currency.code) : nil
        var columnContexts: [String: (decimal: Character?, amounts: Bool, signed: Bool)] = [:]
        for (key, mates) in columns {
            let readings = mates.map { DisplayedNumber.read($0.text, context: ReadingContext(region: convention)) }
            let amounts = readings.contains {
                if case .amount = $0 { return true }
                return false
            }
            // A signed column: amounts with a sign or parentheses beside amounts without.
            let numbered = mates.filter { $0.text.contains { $0.isNumber } }
            let marked = numbered.filter { $0.text.contains { "-−–(".contains($0) } }
            columnContexts[key] = (
                DisplayedNumber.decimalVote(mates.map(\.text)), amounts,
                !marked.isEmpty && marked.count < numbered.count
            )
        }
        let cells = items.enumerated().map { offset, item -> Cell in
            var context = ReadingContext(
                region: convention, inTable: item.table != nil, currency: regionCurrency, macDecimal: macDecimal)
            if let table = item.table, let column = item.column, let found = columnContexts["\(table).\(column)"] {
                context.columnDecimal = found.decimal
                context.columnHoldsAmounts = found.amounts
                context.columnSigned = found.signed
            }
            return Cell(
                id: CellID(offset + 1), text: item.text, reading: DisplayedNumber.read(item.text, context: context),
                box: .zero, table: item.table, row: item.row, column: item.column, suspicious: false)
        }
        return CellSheet(cells: cells, convention: convention, readMs: 0)
    }

    /// A sheet from plain texts, numbered in order, as free lines.
    static func sheet(texts: [String]) -> CellSheet {
        sheet(
            texts.enumerated().map {
                Item(id: "C\($0.offset + 1)", text: $0.element, table: nil, row: nil, column: nil)
            })
    }
}
