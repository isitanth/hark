import CoreGraphics
import Foundation
import HarkCore
import Testing

private typealias F = Fixture

private let us = Locale(identifier: "en_US")

/// Three rows of a label and a number: C1 "A", C2 "10", C3 "B", C4 "20", C5 "C", C6 "30".
private let sheet: CellSheet = {
    let rows = [["A", "10"], ["B", "20"], ["C", "30"]]
    var items: [MathFixtures.Item] = []
    for (row, texts) in rows.enumerated() {
        for (column, text) in texts.enumerated() {
            items.append(.init(id: "C\(items.count + 1)", text: text, table: 0, row: row, column: column))
        }
    }
    let plain = MathFixtures.sheet(items)
    return CellSheet(
        cells: plain.cells.map { cell in
            Cell(
                id: cell.id, text: cell.text, reading: cell.reading,
                box: CGRect(
                    x: 0.2 * Double(cell.column ?? 0), y: 0.1 * Double(cell.row ?? 0), width: 0.18, height: 0.05),
                table: cell.table, row: cell.row, column: cell.column, suspicious: false)
        }, convention: plain.convention, readMs: plain.readMs)
}()

private func entry(_ formula: String, _ understood: String) -> String {
    #"{"understood": "\#(understood)", "formula": "\#(formula)", "unit": "none"}"#
}

private func outcomes(_ entries: [String], kept: [KeptResult] = []) throws -> [ResultOutcome] {
    try MathEngine.solveAll(
        reply: #"{"results": ["# + entries.joined(separator: ", ") + "]}", finishReason: "stop", sheet: sheet,
        instruction: "Totals?", kept: kept
    ).get()
}

/// A turn in review with these results, numbered from `first`, its reply composed as the reducer composes it.
private func reviewing(
    _ results: [ResultOutcome], understood: [String], first: Int = 1, thread: AskThread? = nil
) -> UtteranceContext {
    var context = F.regionContext(region: F.region)
    context.thread = thread
    let numbers = results.indices.map { first + $0 }
    let answers = results.map { outcome in
        try? outcome.map { ExactAnswer($0, sheet: sheet, policy: .standard, fallback: us) }.get()
    }
    context.math = ExactMathContext(
        reading: .read(sheet), routed: true, attempts: 1, computation: results.lazy.compactMap { try? $0.get() }.first,
        results: results, numbers: numbers)
    context.reply = PlanPrompt.composedReply(
        zip(numbers, zip(understood, answers)).map {
            PlanPrompt.ComposedResult(number: $0.0, understood: $0.1.0, answer: $0.1.1)
        })
    return context
}

private let pin = ProfilePin(
    name: "local", baseURL: URL(string: "http://127.0.0.1:8000/v1")!, api: .openAI, model: .auto,
    requestedModel: F.bonsai)

private func kept(_ number: Int, _ shown: String, _ understood: String, turn: UtteranceID) -> KeptResult {
    KeptResult(
        number: number, value: Decimal(number * 10), unit: .number, unitLabel: nil, scale: 0, shown: shown,
        understood: understood, turn: turn)
}

@Suite struct ExactResultsTests {
    @Test func nothingWithoutAComputedResult() throws {
        #expect(AskPresentation.results(nil, locale: us) == nil)
        let failed = try outcomes([entry("C2 / 0", "Nothing.")])
        #expect(AskPresentation.results(reviewing(failed, understood: ["Nothing."]), locale: us) == nil)
    }

    @Test func aLoneResultIsUnnumberedAndMatchesTheOneResultView() throws {
        let context = reviewing(try outcomes([entry("C2 + C4", "The total.")]), understood: ["The total."])
        let results = try #require(AskPresentation.results(context, locale: us))
        #expect(results.blocks.count == 1)
        #expect(results.blocks[0].number == nil)
        #expect(!results.numbered)
        #expect(results.announcement == nil)
        #expect(results.blocks[0].answer == AskPresentation.exact(context, locale: us))
        #expect(results.blocks[0].highlights == AskPresentation.highlights(context))
        #expect(results.copyText == AskPresentation.exactAnswer(context, locale: us)?.result)
    }

    @Test func blocksComeInTheModelsOrderWithTheirNumbers() throws {
        let context = reviewing(
            try outcomes([entry("C6 - C2", "The gap."), entry("C2 + C4", "The total.")]),
            understood: ["The gap.", "The total."])
        let results = try #require(AskPresentation.results(context, locale: us))
        #expect(results.blocks.map(\.number) == [1, 2])
        #expect(results.blocks.map(\.id) == [0, 1])
        #expect(results.blocks.map { $0.answer?.result } == ["20", "30"])
        #expect(results.blocks.map(\.understood) == ["The gap.", "The total."])
        #expect(results.copyText == "20\n30")
        #expect(results.numbered)
    }

    @Test func eachBlockLightsTheCellsItRead() throws {
        let context = reviewing(
            try outcomes([entry("C6 - C2", "The gap."), entry("C4", "The second.")]),
            understood: ["The gap.", "The second."])
        let results = try #require(AskPresentation.results(context, locale: us))
        #expect(results.blocks[0].highlights?.cells.map(\.id) == ["C6", "C2"].map { CellID($0)! })
        #expect(results.blocks[1].highlights?.cells.map(\.id) == [CellID("C4")!])
        #expect(results.blocks.allSatisfy { $0.readsCells })
    }

    @Test func aFailedBlockKeepsItsNumberItsFailureAndItsUnderstood() throws {
        let solved = try outcomes([entry("C2 + C4", "The total."), entry("C6 / 0", "A ratio.")])
        let context = reviewing(solved, understood: ["The total.", "A ratio."])
        let results = try #require(AskPresentation.results(context, locale: us))
        #expect(results.blocks.map(\.number) == [1, 2])
        #expect(results.blocks[1].answer == nil)
        #expect(results.blocks[1].failure != nil)
        #expect(results.blocks[1].understood == "A ratio.")
        #expect(results.copyText == "30")
        let announcement = try #require(results.announcement)
        #expect(announcement.count == 1)
        #expect(announcement.items.map(\.number) == [1])
    }

    @Test func aFollowUpCountsOnAndReadsAKeptResult() throws {
        let root = UtteranceID(41)
        let first = kept(1, "30", "The total.", turn: root)
        let thread = AskThread(
            rootID: root, kind: .selection, selection: "texte", pin: pin,
            turns: [
                AskTurn(
                    id: root, instruction: "Total?", reply: "%% The total.\n\n30", region: F.region,
                    results: [first])
            ])
        let solved = try outcomes([entry("RES1 + RES1", "Twice it.")], kept: [first])
        let context = reviewing(solved, understood: ["Twice it."], first: 2, thread: thread)
        let results = try #require(AskPresentation.results(context, locale: us))
        #expect(results.blocks.map(\.number) == [2])
        #expect(results.blocks[0].answer?.result == "20")
        #expect(results.blocks[0].highlights == nil)
        #expect(!results.blocks[0].readsCells)
        #expect(results.announcement?.items.map(\.spoken) == ["20"])
    }

    @Test func theAnnouncementHoldsEveryComputedResult() throws {
        let context = reviewing(
            try outcomes([entry("C2", "One."), entry("C4", "Two."), entry("C6", "Three.")]),
            understood: ["One.", "Two.", "Three."])
        let announcement = try #require(AskPresentation.results(context, locale: us)?.announcement)
        #expect(announcement.count == 3)
        #expect(announcement.items.map(\.number) == [1, 2, 3])
        #expect(announcement.items.map(\.spoken) == ["10", "20", "30"])
    }

    @Test func aPositionNamesItsBlock() throws {
        let context = reviewing(
            try outcomes([entry("C2", "One."), entry("C4", "Two.")]), understood: ["One.", "Two."])
        let results = try #require(AskPresentation.results(context, locale: us))
        #expect(results.block(at: 1)?.number == 2)
        #expect(results.block(at: 2) == nil)
    }

    @Test func anEarlierExactTurnFoldsToItsKeptResults() {
        let root = UtteranceID(41)
        let reply = "%% ① The total. ② A ratio.\n\n① 10 + 20 =\n① 30\n② not computed"
        let thread = AskThread(
            rootID: root, kind: .selection, selection: "texte", pin: pin,
            turns: [
                AskTurn(
                    id: root, instruction: "Totals?", reply: reply, region: F.region,
                    results: [kept(1, "30", "The total.", turn: root)], numbers: [1, 2])
            ])
        var follow = F.regionContext(region: F.region)
        follow.thread = thread
        let row = AskPresentation.earlierTurns(follow).first
        #expect(row?.foldedLine == "① 30 · ② —")
        #expect(row?.results.map(\.understood) == ["The total.", nil])
        #expect(row?.answer.isEmpty == true)
        #expect(row?.restatement == nil)
        #expect(row.map { !$0.answer.contains("not computed") && $0.answer != reply } == true)
    }

    @Test func aLoneEarlierResultFoldsAsIn010() {
        let root = UtteranceID(41)
        let thread = AskThread(
            rootID: root, kind: .selection, selection: "texte", pin: pin,
            turns: [
                AskTurn(
                    id: root, instruction: "Total?", reply: "%% The total.\n\n10 + 20 =\n30", region: F.region,
                    results: [kept(1, "30", "The total.", turn: root)])
            ])
        var follow = F.regionContext(region: F.region)
        follow.thread = thread
        let row = AskPresentation.earlierTurns(follow).first
        #expect(row?.results.isEmpty == true)
        #expect(row?.foldedLine == "30")
    }
}
