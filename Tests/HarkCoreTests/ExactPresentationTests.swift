import CoreGraphics
import Foundation
import HarkCore
import Testing

private typealias F = Fixture

private func snapshot(_ state: PipelineState) -> PipelineSnapshot {
    PipelineSnapshot(phase: state.phase, utterance: state.context, ask: state.ask)
}

/// A grid laid out on a 5-column, 0.06-high lattice: column c, row r sits at (0.2 c, 0.06 r).
private func boxed(_ sheet: CellSheet, suspicious: Set<Int> = []) -> CellSheet {
    CellSheet(
        cells: sheet.cells.map { cell in
            let box =
                cell.table == nil
                ? CGRect(x: 0, y: 0.9, width: 0.5, height: 0.04)
                : CGRect(
                    x: 0.2 * Double(cell.column ?? 0), y: 0.06 * Double(cell.row ?? 0), width: 0.18, height: 0.05)
            return Cell(
                id: cell.id, text: cell.text, reading: cell.reading, box: box, table: cell.table, row: cell.row,
                column: cell.column, suspicious: suspicious.contains(cell.id.index))
        }, convention: sheet.convention, readMs: sheet.readMs)
}

private func grid(_ rows: [[String]]) -> CellSheet {
    var items: [MathFixtures.Item] = []
    for (row, texts) in rows.enumerated() {
        for (column, text) in texts.enumerated() {
            items.append(.init(id: "C\(items.count + 1)", text: text, table: 0, row: row, column: column))
        }
    }
    return boxed(MathFixtures.sheet(items))
}

private func computation(
    _ sheet: CellSheet, _ formula: String, unit: String = "none", understood: String = "You want the total.",
    instruction: String = "How much in total?"
) throws -> Computation {
    try MathEngine.solve(
        reply: planReply(formula, unit: unit, understood: understood), finishReason: "stop", sheet: sheet,
        instruction: instruction
    ).get()
}

private func exactContext(
    _ sheet: CellSheet, _ computation: Computation?, region: RegionSummary? = F.region,
    intent: CaptureIntent = F.ask
) -> UtteranceContext {
    var context = F.regionContext(intent: intent, region: region)
    context.math = ExactMathContext(reading: .read(sheet), routed: true, attempts: 1, computation: computation)
    return context
}

/// With every warning swapped for the ones given.
private func warned(_ computation: Computation, _ warnings: [MathWarning]) -> Computation {
    Computation(
        plan: computation.plan, formula: computation.formula, value: computation.value, unit: computation.unit,
        read: computation.read, roles: computation.roles, winner: computation.winner, warnings: warnings)
}

private let c01 = MathFixtures.golden.first { $0.id.hasPrefix("c01") }

private func c01Context() throws -> UtteranceContext {
    let golden = try #require(c01)
    let sheet = boxed(MathFixtures.sheet(golden.grid), suspicious: [23])
    let solved = try MathEngine.solve(
        reply: golden.exact, finishReason: "stop", sheet: sheet, instruction: golden.question
    ).get()
    return exactContext(sheet, solved)
}

/// ICU's spaces move with the OS: compare with every no-break space as a plain one.
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
}

private let us = Locale(identifier: "en_US")

private let pin = ProfilePin(
    name: "local", baseURL: URL(string: "http://127.0.0.1:8000/v1")!, api: .openAI, model: .auto,
    requestedModel: F.bonsai)

private func thread(_ root: UtteranceID, _ turns: [AskTurn]) -> AskThread {
    AskThread(rootID: root, kind: .selection, selection: "texte", pin: pin, turns: turns)
}

@Suite struct ExactPresentationTests {
    @Test(arguments: [
        (AskStage.reading, false, AskPanelState.reading),
        (.reading, true, .reading),
        (.planning, false, .planning),
        (.planning, true, .planning),
        (.mathFailed(.reader(.vision)), false, .mathFailed(.reader(.vision))),
        (.mathFailed(.reader(.timeout)), true, .mathFailed(.reader(.timeout))),
        (.mathFailed(.plan(.unit("EUR + USD"))), false, .mathFailed(.plan(.unit("EUR + USD")))),
        (.mathFailed(.plan(.truncated)), true, .mathFailed(.plan(.truncated))),
        (
            .mathFailed(.math(.divisionByZero, cell: CellID(2))), false,
            .mathFailed(.math(.divisionByZero, cell: CellID(2)))
        ),
        (.mathFailed(.math(.overflow, cell: nil)), true, .mathFailed(.math(.overflow, cell: nil))),
        (.reviewing, true, .reviewing),
    ])
    func theExactStagesHaveTheirPanelStates(_ stage: AskStage, _ streamed: Bool, _ expected: AskPanelState) {
        let state = PipelineState.asking(F.regionContext(region: F.region), F.instruction, stage)
        #expect(AskPresentation.state(snapshot(state), streamed: streamed) == expected)
    }

    @Test func noComputationNoExactAnswer() throws {
        let sheet = grid([["€1.00", "€2.00"]])
        #expect(AskPresentation.exact(exactContext(sheet, nil), locale: us) == nil)
        #expect(AskPresentation.highlights(exactContext(sheet, nil)) == nil)
        #expect(AskPresentation.exact(F.regionContext(region: F.region), locale: us) == nil)
        #expect(AskPresentation.exact(nil, locale: us) == nil)
    }

    @Test func c01InTheUsersFormatWithTheWorkingAsRead() throws {
        let context = try c01Context()
        let american = try #require(AskPresentation.exact(context, locale: us))
        let french = try #require(AskPresentation.exact(context, locale: Locale(identifier: "fr_FR")))
        #expect(american.result == "€802.42")
        #expect(plain(french.result) == "802,42 €")
        #expect(french.result.contains("\u{00A0}") || french.result.contains("\u{202F}"))
        #expect(american.working == french.working)
        #expect(american.working?.hasPrefix("€145.00 − €62.50 + €176.50") == true)
        #expect(american.exact == nil)
        #expect(american.cellsUsed == 11 && american.added == 8 && american.subtracted == 3)
        #expect(american.showsSigns)
        #expect(american.rows.count == 11)
        #expect(american.rows.filter(\.uncertain).map(\.id) == [CellID(23)])
    }

    @Test func exactIsSetOnlyWhenRoundingChangedTheValue() throws {
        let sheet = grid([["$189.39"]])
        let rounded = try computation(sheet, "C1 / 4", instruction: "split four ways")
        let presented = try #require(AskPresentation.exact(exactContext(sheet, rounded), locale: us))
        #expect(presented.result == "$47.35")
        #expect(presented.exact == "$47.3475")
        let even = grid([["$189.40"]])
        let whole = try computation(even, "C1 / 4", instruction: "split four ways")
        #expect(AskPresentation.exact(exactContext(even, whole), locale: us)?.exact == nil)
    }

    @Test func aCellReadTwiceCountsOnce() throws {
        let sheet = grid([["€10.00", "€4.00"]])
        let solved = try computation(sheet, "C1 + C1 - C2")
        let presented = try #require(AskPresentation.exact(exactContext(sheet, solved), locale: us))
        #expect(presented.cellsUsed == 2)
        #expect(presented.added == 1 && presented.subtracted == 1)
        #expect(presented.rows.map(\.id) == [CellID(1), CellID(2)])
    }

    @Test func signsShowOnlyWhenBothAreThere() throws {
        let sheet = grid([["€10.00", "€4.00"]])
        let sum = try #require(
            AskPresentation.exact(exactContext(sheet, try computation(sheet, "C1 + C2")), locale: us))
        #expect(sum.added == 2 && sum.subtracted == 0 && !sum.showsSigns)
        let count = try #require(
            AskPresentation.exact(exactContext(sheet, try computation(sheet, "COUNT(C1, C2)")), locale: us))
        #expect(count.added == 2, "counted counts as added")
        #expect(count.rows.allSatisfy { $0.role == .counted })
        #expect(count.working == nil)
    }

    @Test func rowsComeInReadingOrderWithTheirLabels() throws {
        let sheet = grid([
            ["Lunch", "€12.00"],
            ["A very long description of a team dinner", "Paris", "€40.00"],
        ])
        let solved = try computation(sheet, "C5 + C2")
        let rows = try #require(AskPresentation.exact(exactContext(sheet, solved), locale: us)).rows
        #expect(rows.map(\.id) == [CellID(2), CellID(5)])
        #expect(rows[0].label == "Lunch")
        #expect(rows[0].text == "€12.00")
        #expect(rows[1].label.count == AskPresentation.labelLimit)
        #expect(rows[1].label.hasSuffix("…"))
        #expect(rows[1].label.hasPrefix("A very long description of a team"))
    }

    /// A misread number beside the cell is no word: the row is named by its words only.
    @Test func aGarbledMateIsNoLabel() throws {
        let sheet = grid([["Lunch", "£21,32łł", "€12.00"]])
        let solved = try computation(sheet, "C3")
        let rows = try #require(AskPresentation.exact(exactContext(sheet, solved), locale: us)).rows
        #expect(sheet[CellID(2)]?.reading == .garbled)
        #expect(rows.map(\.label) == ["Lunch"])
    }

    @Test func aFreeLineHasNoLabel() throws {
        let sheet = boxed(MathFixtures.sheet(texts: ["Total €12.00", "€3.00"]))
        let solved = try computation(sheet, "C1 + C2")
        let rows = try #require(AskPresentation.exact(exactContext(sheet, solved), locale: us)).rows
        #expect(rows.allSatisfy { $0.label.isEmpty })
    }

    @Test(arguments: [
        ([MathWarning](), false),
        ([.doubt(CellID(1))], true),
        ([.scaleMismatch(CellID(1))], true),
        ([.suspiciousCell(CellID(1))], true),
        ([.doubt(CellID(2))], false),
        ([.dashAsZero(CellID(1)), .parenthesized(CellID(1)), .tie(CellID(1)), .approximate], false),
    ])
    func uncertainFromTheReaderOrAWarning(_ warnings: [MathWarning], _ expected: Bool) throws {
        let sheet = grid([["€10.00", "€4.00"]])
        let solved = warned(try computation(sheet, "C1 + C2"), warnings)
        let context = exactContext(sheet, solved)
        let row = try #require(AskPresentation.exact(context, locale: us)?.rows.first)
        #expect(row.uncertain == expected)
        #expect(AskPresentation.highlights(context)?.cells.first?.uncertain == expected)
    }

    @Test func aSuspiciousCellIsUncertain() throws {
        let sheet = boxed(MathFixtures.sheet(texts: ["€10.00", "€4.00"]), suspicious: [2])
        let rows = try #require(
            AskPresentation.exact(exactContext(sheet, try computation(sheet, "C1 + C2")), locale: us)
        ).rows
        #expect(rows.map(\.uncertain) == [false, true])
    }

    @Test(arguments: [
        ([UnderstoodFigure](), nil as UnderstoodCheck?),
        ([UnderstoodFigure(text: "€10.00", source: .cell(CellID(1)))], nil),
        (
            [
                UnderstoodFigure(text: "€10.00", source: .cell(CellID(1))),
                UnderstoodFigure(text: "12 %", source: .spoken),
            ],
            .spoken("12 %")
        ),
        ([UnderstoodFigure(text: "731.10", source: .nowhere)], .notRead("731.10")),
        (
            [UnderstoodFigure(text: "731.10", source: .nowhere), UnderstoodFigure(text: "12 %", source: .spoken)],
            .notRead("731.10")
        ),
    ])
    func theUnderstoodCheckMapsTheFirstFlaggedFigure(_ figures: [UnderstoodFigure], _ expected: UnderstoodCheck?) {
        #expect(AskPresentation.understoodCheck(figures) == expected)
    }

    @Test func theUnderstoodCheckFromAComputedAnswer() throws {
        let sheet = grid([["145,00 €", "99,00 €"]])
        let spoken = try computation(
            sheet, "SUM(C1, C2) * 1.12", understood: "You want 145,00 € and 99,00 €, plus 12 %.",
            instruction: "with 12 % more")
        #expect(AskPresentation.exact(exactContext(sheet, spoken), locale: us)?.understoodCheck == .spoken("12 %"))
        let plainSum = try computation(sheet, "C1 + C2", understood: "You want 145,00 € and 99,00 €.")
        #expect(AskPresentation.exact(exactContext(sheet, plainSum), locale: us)?.understoodCheck == nil)
        let empty = try computation(sheet, "C1 + C2", understood: "")
        let presented = try #require(AskPresentation.exact(exactContext(sheet, empty), locale: us))
        #expect(presented.understood == nil && presented.understoodCheck == nil)
    }

    @Test(arguments: [
        (
            [MathWarning.tie(CellID(1)), .approximate, .doubt(CellID(2))], 2,
            [MathWarning.doubt(CellID(2)), .approximate]
        ),
        ([.rounded(exact: 1), .assumedConvention], 2, [.assumedConvention]),
        (
            [.parenthesized(CellID(1)), .dashAsZero(CellID(2)), .scaleMismatch(CellID(1))], 1,
            [.scaleMismatch(CellID(1))]
        ),
        (
            [.suspiciousCell(CellID(1)), .suspiciousCell(CellID(2)), .tie(CellID(1))], 2,
            [.suspiciousCell(CellID(1)), .tie(CellID(1))]
        ),
        ([.approximate], 0, []),
    ])
    func checksComeInOrderAndTwoAtMost(_ warnings: [MathWarning], _ limit: Int, _ expected: [MathWarning]) {
        #expect(AskPresentation.checks(warnings, limit: limit) == expected)
    }

    @Test func theUnderstoodCheckTakesOneOfTheTwoLines() throws {
        let sheet = grid([["145,00 €", "99,00 €"]])
        let solved = warned(
            try computation(
                sheet, "SUM(C1, C2) * 1.12", understood: "You want 145,00 € and 99,00 €, plus 12 %.",
                instruction: "with 12 % more"),
            [.approximate, .doubt(CellID(1)), .rounded(exact: 1)])
        let presented = try #require(AskPresentation.exact(exactContext(sheet, solved), locale: us))
        #expect(presented.understoodCheck != nil)
        #expect(presented.checks == [.doubt(CellID(1))])
        #expect(presented.named == [CellID(1): "145,00 €"])
    }

    @Test(arguments: [
        (CGRect(x: 0, y: 0, width: 1000, height: 500), CGRect(x: 198, y: 28, width: 184, height: 29)),
        (CGRect(x: 1600, y: 300, width: 500, height: 1000), CGRect(x: 1698, y: 358, width: 94, height: 54)),
        (CGRect(x: 10.5, y: 20.5, width: 200, height: 100), CGRect(x: 48.5, y: 24.5, width: 40, height: 9)),
    ])
    func aHighlightIsTheNormalizedBoxOnTheFramePadded(_ frame: CGRect, _ expected: CGRect) throws {
        var items: [MathFixtures.Item] = []
        items.append(.init(id: "C1", text: "€1.00", table: 0, row: 0, column: 0))
        items.append(.init(id: "C2", text: "€2.00", table: 0, row: 1, column: 1))
        let sheet = boxed(MathFixtures.sheet(items))
        // C2 sits at (0.2, 0.06), 0.18 by 0.05.
        let region = RegionSummary(rect: frame, pixelWidth: 1, pixelHeight: 1, bytes: 1, displayID: 7)
        let solved = try computation(sheet, "C2")
        let highlights = try #require(AskPresentation.highlights(exactContext(sheet, solved, region: region)))
        #expect(highlights.displayID == 7 && highlights.frame == frame)
        let cell = try #require(highlights.cells.first)
        #expect(highlights.cells.count == 1, "an unread cell has no box")
        #expect(abs(cell.box.minX - expected.minX) < 0.001 && abs(cell.box.minY - expected.minY) < 0.001)
        #expect(abs(cell.box.width - expected.width) < 0.001 && abs(cell.box.height - expected.height) < 0.001)
    }

    @Test func eachHighlightHasItsRole() throws {
        let sheet = grid([["€10.00", "€4.00", "€3.00"]])
        let solved = try computation(sheet, "C1 - C2 + C3")
        let highlights = try #require(AskPresentation.highlights(exactContext(sheet, solved)))
        #expect(highlights.cells.map(\.role) == [.added, .subtracted, .added])
        #expect(highlights.frameID == F.regionContext().id)
    }

    @Test func aFollowUpWithoutAFrameLightsTheLatestFramedSheet() throws {
        let sheet = grid([["€10.00", "€4.00"]])
        let earlier = UtteranceID(41)
        let region = RegionSummary(
            rect: CGRect(x: 5, y: 5, width: 100, height: 100), pixelWidth: 1, pixelHeight: 1, bytes: 1, displayID: 3)
        var context = exactContext(sheet, try computation(sheet, "C1 + C2"), region: nil)
        context.thread = thread(
            earlier,
            [
                AskTurn(id: earlier, instruction: "Total?", reply: "%% x\n\n1", region: region, sheet: sheet),
                AskTurn(id: UtteranceID(42), instruction: "And?", reply: "%% y\n\n2", region: nil, sheet: sheet),
            ])
        let highlights = try #require(AskPresentation.highlights(context))
        #expect(highlights.frameID == earlier)
        #expect(highlights.displayID == 3)
    }

    @Test(arguments: [
        (CGPoint(x: 150, y: 1080 - 100), true),
        (CGPoint(x: 50, y: 1080 - 100), false),
        (CGPoint(x: 120, y: 1080 - 80), true),
        (CGPoint(x: 820, y: 1080 - 680), true),
        (CGPoint(x: 821, y: 1080 - 680), false),
    ])
    func theHitTestOnTheMainDisplay(_ point: CGPoint, _ inside: Bool) {
        let highlights = CellHighlights(frameID: UtteranceID(1), displayID: 1, frame: F.region.rect, cells: [])
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(highlights.contains(cocoaPoint: point, displayFrame: display) == inside)
    }

    /// A display left of and below the main one: Cocoa origin (-1440, -900), 1440 by 900.
    @Test(arguments: [
        (CGPoint(x: -1440 + 150, y: -900 + 900 - 100), true),
        (CGPoint(x: -1440 + 150, y: -900 + 900 - 700), false),
        (CGPoint(x: 150, y: 1080 - 100), false),
    ])
    func theHitTestOnADisplayWithANegativeOrigin(_ point: CGPoint, _ inside: Bool) {
        let highlights = CellHighlights(frameID: UtteranceID(1), displayID: 2, frame: F.region.rect, cells: [])
        let display = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        #expect(highlights.contains(cocoaPoint: point, displayFrame: display) == inside)
    }

    @Test(arguments: [MathDefect.noNumber, .garbled, .divisionByZero])
    func aMathFailureOutlinesItsCell(_ defect: MathDefect) throws {
        let sheet = grid([["€10.00", "n/a"]])
        let context = exactContext(sheet, nil)
        let highlights = try #require(AskPresentation.failureCell(.math(defect, cell: CellID(2)), utterance: context))
        #expect(highlights.cells.map(\.id) == [CellID(2)])
        #expect(highlights.cells.first?.role == nil)
    }

    @Test(arguments: [
        MathFailure.math(.noNumber, cell: nil), .math(.garbled, cell: CellID(99)), .math(.overflow, cell: CellID(1)),
        .plan(.degenerate), .plan(.unspokenConstant("3")), .reader(.vision), .reader(.timeout),
    ])
    func otherFailuresOutlineNothing(_ failure: MathFailure) {
        let sheet = grid([["€10.00", "n/a"]])
        #expect(AskPresentation.failureCell(failure, utterance: exactContext(sheet, nil)) == nil)
    }

    @Test func anExactTurnFoldsToItsResult() throws {
        let context = try c01Context()
        let reply = try #require(AskPresentation.exactAnswer(context, locale: us)).reply
        var follow = F.regionContext(region: F.region)
        follow.thread = thread(
            context.id,
            [AskTurn(id: context.id, instruction: "Total?", reply: reply, region: F.region)])
        #expect(AskPresentation.earlierTurns(follow).first?.foldedLine == "€802.42")
    }

    @Test func aPickTurnFoldsToItsLabelAndValue() throws {
        let sheet = grid([["Big", "£2.69", "1500g"], ["Small", "£1.79", "400g"]])
        let pick = try computation(sheet, "ARGMIN(C2 @ C1, C5 @ C4)", instruction: "Which is cheaper?")
        let context = exactContext(sheet, pick)
        let reply = try #require(AskPresentation.exactAnswer(context, locale: Locale(identifier: "en_GB"))).reply
        var follow = F.regionContext(region: F.region)
        follow.thread = thread(
            context.id,
            [AskTurn(id: context.id, instruction: "Which?", reply: reply, region: F.region)])
        #expect(AskPresentation.earlierTurns(follow).first?.foldedLine == "Small — £1.79")
    }

    @Test func anExactSelectionAskCopiesAndAnExactAssistantAskInserts() throws {
        let sheet = grid([["€10.00"]])
        let solved = try computation(sheet, "C1")
        #expect(AskPresentation.apply(exactContext(sheet, solved)) == .copyOnly)
        #expect(AskPresentation.apply(exactContext(sheet, solved, intent: F.assist)) == .insert)
    }
}

@Suite struct FailureCellTextTests {
    @Test(arguments: [
        (MathFailure.math(.noNumber, cell: CellID(2)), "n/a" as String?),
        (.math(.garbled, cell: CellID(2)), "n/a"),
        (.math(.noNumber, cell: nil), nil),
        (.math(.garbled, cell: CellID(9)), nil),
        (.math(.divisionByZero, cell: CellID(2)), nil),
        (.plan(.json), nil),
        (.reader(.vision), nil),
    ])
    func theLineNamesTheCellAsRead(_ failure: MathFailure, _ expected: String?) {
        let sheet = grid([["€10.00", "n/a"]])
        #expect(AskPresentation.failureCellText(failure, utterance: exactContext(sheet, nil)) == expected)
    }
}
