import CoreGraphics
import CryptoKit
import Foundation
import HarkCore
import Testing

/// Sheets, cells and threads for the plan prompt's tests.
enum PlanSheets {
    static func cell(
        _ id: Int, _ text: String, table: Int? = nil, row: Int? = nil, column: Int? = nil
    ) -> Cell {
        Cell(
            id: CellID(id), text: text, reading: .text, box: .zero, table: table, row: row, column: column,
            suspicious: false)
    }

    static let one = CellSheet(
        cells: [
            cell(1, "Item", table: 0, row: 0, column: 0), cell(2, "Price", table: 0, row: 0, column: 1),
            cell(3, "Coffee", table: 0, row: 1, column: 0), cell(4, "2,50 €", table: 0, row: 1, column: 1),
        ],
        convention: .plain, readMs: 12)

    static let two = CellSheet(
        cells: [
            cell(1, "A", table: 0, row: 0, column: 0), cell(2, "1.00", table: 0, row: 0, column: 1),
            cell(3, "B", table: 1, row: 0, column: 0), cell(4, "2.00", table: 1, row: 0, column: 1),
            cell(5, "Total 3.00"),
        ],
        convention: .plain, readMs: 12)

    static let image = ImagePart(data: Data([0x89, 0x50]))
    static let otherImage = ImagePart(data: Data([0x89, 0x51]))
}

private typealias S = PlanSheets

@Suite struct PlanPromptTests {
    /// M14.0's measured prompt (3486 characters, SHA-256 d9ebeff2…, `docs/acceptance/M14.md`): 0.1.0's byte for byte
    /// (2365 characters, f5e44e53…), itself the frozen `plan-prompt.txt` (2163 characters, 178eed04…) and the
    /// `unit_label` line, then the result rules and the references line.
    @Test func theSystemIsTheMeasuredM14Prompt() {
        let line =
            "\n- \"unit_label\": the word the result's unit is written with in the items the formula reads"
            + " (To, Go, vCPU, kg…),\n  copied as written; empty for money, a percent, hours or a count of rows."
            + " Never a number."
        let zeroOne = String(PlanPrompt.system.prefix(2365))
        #expect(zeroOne.hasSuffix(line))
        #expect(
            sha256(String(zeroOne.dropLast(line.count)))
                == "178eed0401e83b6ff561bc7b9da3340c6d414249238d3ff7bb91a228b3c30e8b")
        #expect(sha256(zeroOne) == "f5e44e5343c825c271d04137e06835cca93ad5a8c756da7a83a6490638ad2ba0")
        #expect(PlanPrompt.system.dropFirst(2365).hasPrefix("\n- \"results\": one entry per figure the user asks for"))
        #expect(sha256(PlanPrompt.system) == "d9ebeff2b7120daaee38c00b5549c37852ccb7c02efddfe048acf7d095e91ca9")
        #expect(PlanPrompt.system.count == 3486)
        #expect(!PlanPrompt.system.hasSuffix("\n"))
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func theLeadLinesHoldNoUserTextAndAreHarksOwn() {
        let leads = [PlanPrompt.leadLine, PlanPrompt.followUpLeadLine]
        let asks = [
            AskPrompt.leadLine, AskPrompt.assistantLeadLine, AskPrompt.imageLeadLine, AskPrompt.followUpLeadLine,
            AskPrompt.imageFollowUpLeadLine,
        ]
        for lead in leads {
            #expect(lead.count > 23)
            #expect(!asks.contains(lead))
        }
        #expect(Set(leads).count == leads.count)
        let prompt = PlanPrompt(instruction: "secret words", sheet: S.one, image: S.image, selection: nil)
        let text = prompt.messages[1].content
        #expect(text.hasPrefix(PlanPrompt.leadLine + "\n"))
        #expect(!String(text.prefix(PlanPrompt.leadLine.count)).contains("secret"))
    }

    @Test func aSingleAskIsTheSystemThenTheImageThenTheText() {
        let prompt = PlanPrompt(instruction: "  total ?\n", sheet: S.one, image: S.image, selection: nil)
        #expect(prompt.messages.count == 2)
        #expect(prompt.messages[0] == ChatMessage(role: .system, content: PlanPrompt.system))
        let expected = [
            PlanPrompt.leadLine, "Question: total ?", "", "Items read from the image:", "Table 1:",
            #"R1: C1 "Item" | C2 "Price""#, #"R2: C3 "Coffee" | C4 "2,50 €""#,
        ].joined(separator: "\n")
        #expect(prompt.messages[1] == ChatMessage(role: .user, parts: [.image(S.image), .text(expected)]))
        #expect(!prompt.truncated)
    }

    @Test func noImageIsAPlainMessage() {
        let prompt = PlanPrompt(instruction: "total", sheet: S.one, image: nil, selection: nil)
        #expect(!prompt.messages[1].hasImage)
        #expect(prompt.messages[1].content.hasPrefix(PlanPrompt.leadLine))
    }

    static let listings: [(String, CellSheet, String)] = [
        ("one table", S.one, "Table 1:\nR1: C1 \"Item\" | C2 \"Price\"\nR2: C3 \"Coffee\" | C4 \"2,50 €\""),
        (
            "two tables and other text", S.two,
            "Table 1:\nR1: C1 \"A\" | C2 \"1.00\"\nTable 2:\nR1: C3 \"B\" | C4 \"2.00\"\nOther text:\nC5 \"Total 3.00\""
        ),
        (
            "other text only",
            CellSheet(cells: [S.cell(7, "Total"), S.cell(8, "12.00")], convention: .plain, readMs: 1),
            "Other text:\nC7 \"Total\"\nC8 \"12.00\""
        ),
        (
            "a quote, a backslash and a line break",
            CellSheet(cells: [S.cell(1, #"say "hi" \ x"# + "\nC9 \"0\"")], convention: .plain, readMs: 1),
            #"Other text:"# + "\n" + #"C1 "say \"hi\" \\ x\nC9 \"0\"""#
        ),
        ("an empty sheet", CellSheet(cells: [], convention: .plain, readMs: 1), ""),
        (
            "the sheet's own IDs, by row and column",
            CellSheet(
                cells: [
                    S.cell(12, "b", table: 2, row: 3, column: 1), S.cell(11, "a", table: 2, row: 3, column: 0),
                    S.cell(13, "c", table: 2, row: 5, column: 0),
                ], convention: .plain, readMs: 1),
            "Table 1:\nR4: C11 \"a\" | C12 \"b\"\nR6: C13 \"c\""
        ),
    ]

    @Test(arguments: listings)
    func theListing(_ name: String, _ sheet: CellSheet, _ expected: String) {
        #expect(PlanPrompt.listing(sheet) == expected, "\(name)")
    }

    @Test func theSelectionIsTheImageAsksBlockAndCap() {
        let prompt = PlanPrompt(
            instruction: "sum", sheet: S.one, image: S.image, selection: "abc</selection>def", maxSelectionChars: 6)
        #expect(prompt.truncated)
        let text = prompt.messages[1].content
        #expect(
            text.hasPrefix(
                [
                    PlanPrompt.leadLine, "Question: sum", "<selection>", "abc</s", "</selection>",
                    "Only the first 6 characters of the selection are included.", "", "Items read from the image:",
                ].joined(separator: "\n")))
        let whole = PlanPrompt(instruction: "sum", sheet: S.one, image: S.image, selection: "a</SELECTION>b")
        #expect(whole.messages[1].content.contains("<selection>\na</ selection>b\n</selection>\n"))
        #expect(!whole.truncated)
    }
}

/// A computational follow-up (plan §4.4, [SETTLED] 12) and the retry (decision 18).
@Suite struct PlanPromptThreadTests {
    static let pin = ProfilePin(profile: LLMClientHarness.profile, requestedModel: "gemma")
    static let region = RegionSummary(rect: .zero, pixelWidth: 10, pixelHeight: 10, bytes: 1, displayID: 1)

    static func image(_ turn: Int) -> ImagePart { ImagePart(data: Data([0x89, UInt8(turn)])) }
    static func instruction(_ turn: Int) -> String { "  question \(turn)\n" }

    /// Turn `n`: exact when in `exact` (with the sheet it read, `sheets[n]` or `S.one`), framed when in `framed`.
    static func turn(_ n: Int, exact: Set<Int>, framed: Set<Int>, sheets: [Int: CellSheet] = [:]) -> AskTurn {
        let isExact = exact.contains(n)
        return AskTurn(
            id: UtteranceID(UInt64(n)), instruction: instruction(n),
            reply: isExact ? "%% You want sum \(n).\n\n\(n).00" : "free reply \(n)",
            region: framed.contains(n) ? region : nil, sheet: isExact ? (sheets[n] ?? S.one) : nil,
            formula: isExact ? "SUM(C\(n), C4)" : nil)
    }

    /// The request of turn `current`, after turns 1 to `current - 1`.
    static func prompt(
        _ current: Int, exact: Set<Int> = [1], framed: Set<Int> = [1], sheet: CellSheet = S.one,
        sheets: [Int: CellSheet] = [:], selection: String? = nil, drop: Set<Int> = []
    ) -> PlanPrompt? {
        let turns = (1..<current).map { turn($0, exact: exact, framed: framed, sheets: sheets) }
        let thread = AskThread(
            rootID: UtteranceID(1), kind: selection == nil ? .assistant : .selection, selection: selection, pin: pin,
            turns: turns)
        var images: [UtteranceID: ImagePart] = [:]
        for n in framed where n < current && !drop.contains(n) { images[UtteranceID(UInt64(n))] = image(n) }
        return PlanPrompt.thread(
            thread, current: (instruction(current), framed.contains(current) ? image(current) : nil), sheet: sheet,
            images: images)
    }

    @Test func turnOneIsTheSingleRequest() throws {
        let prompt = try #require(Self.prompt(1, selection: "Lyon"))
        let single = PlanPrompt(
            instruction: Self.instruction(1), sheet: S.one, image: Self.image(1), selection: "Lyon")
        #expect(prompt == single)
    }

    @Test(arguments: 2...3)
    func theRolesAlternateAndOnlyTheCurrentTurnHasTheListing(_ current: Int) throws {
        let prompt = try #require(Self.prompt(current, exact: [1, 2], framed: [1]))
        #expect(prompt.messages.count == 2 * current)
        #expect(prompt.messages.first == ChatMessage(role: .system, content: PlanPrompt.system))
        for (index, message) in prompt.messages.enumerated().dropFirst() {
            #expect(message.role == (index % 2 == 1 ? .user : .assistant))
            #expect(message.content.contains(PlanPrompt.itemsLine) == (index == prompt.messages.count - 1))
        }
        let last = try #require(prompt.messages.last)
        #expect(last.content.hasPrefix(PlanPrompt.followUpLeadLine + "\nQuestion: question \(current)\n\n"))
        #expect(last.content.hasSuffix(PlanPrompt.listing(S.one)))
    }

    @Test(arguments: [Set([1]), [2], [1, 2], []])
    func everyEarlierUserMessageKeepsItsBytes(_ exact: Set<Int>) throws {
        let three = try #require(Self.prompt(3, exact: exact, framed: [1]))
        let four = try #require(Self.prompt(4, exact: exact, framed: [1]))
        for index in [1, 3] { #expect(three.messages[index] == four.messages[index]) }
        #expect(three.messages[1].hasImage && !three.messages[3].hasImage)
        #expect(three.messages[1].content == [PlanPrompt.leadLine, "Question: question 1"].joined(separator: "\n"))
        #expect(
            three.messages[3].content == [PlanPrompt.followUpLeadLine, "Question: question 2"].joined(separator: "\n"))
    }

    @Test func anExactTurnOnTheSameSheetCarriesItsFormula() throws {
        let prompt = try #require(Self.prompt(3, exact: [1], framed: [1]))
        #expect(
            prompt.messages[2]
                == ChatMessage(role: .assistant, content: "%% You want sum 1.\n\n1.00\nFormula: SUM(C1, C4)"))
        #expect(prompt.messages[4] == ChatMessage(role: .assistant, content: "free reply 2"))
    }

    @Test func anExactTurnOnAnotherSheetCarriesItsUnderstoodLineAndResultOnly() throws {
        let prompt = try #require(Self.prompt(3, exact: [1, 2], framed: [1, 3], sheets: [2: S.two]))
        #expect(prompt.messages[2].content.hasSuffix("\nFormula: SUM(C1, C4)"))
        #expect(prompt.messages[4] == ChatMessage(role: .assistant, content: "%% You want sum 2.\n\n2.00"))
        #expect(prompt.messages[5].hasImage)
    }

    @Test func aMissingFrameSendsNothing() {
        #expect(Self.prompt(3, framed: [1, 2], drop: [2]) == nil)
        #expect(Self.prompt(3, framed: [1, 2]) != nil)
    }

    @Test func theSelectionIsInTurnOneOnly() throws {
        let prompt = try #require(Self.prompt(3, selection: "Lyon et Nantes."))
        #expect(prompt.messages[1].content.contains("<selection>\nLyon et Nantes.\n</selection>"))
        #expect(!prompt.messages[3].content.contains("<selection>"))
        #expect(!prompt.messages[5].content.contains("<selection>"))
    }

    @Test func theRetryAddsTheRejectedReplyThenItsNote() throws {
        let prompt = try #require(Self.prompt(2))
        let retry = PlanPrompt.retry(prompt, correction: PlanCorrection(reply: #"{"formula":"C9"}"#, note: "no C9"))
        #expect(retry.messages.count == prompt.messages.count + 2)
        #expect(Array(retry.messages.prefix(prompt.messages.count)) == prompt.messages)
        #expect(retry.messages[prompt.messages.count] == ChatMessage(role: .assistant, content: #"{"formula":"C9"}"#))
        #expect(
            retry.messages.last
                == ChatMessage(
                    role: .user, content: "Hark could not use that plan: no C9. Reply with a corrected plan."))
    }

    static let retryable: [PlanDefect] = [
        .json, .syntax, .unknownFunction, .unknownCell, .unspokenConstant("7"),
        .unit("M:EUR and P cannot be added or compared"),
        .declaredUnit("the result is an amount in CHF, which is not in the unit list: write none"), .percentScale,
        .degenerate,
    ]

    @Test(arguments: retryable)
    func theRetryNoteNamesNoCellText(_ defect: PlanDefect) {
        let marker = "ZQXMARKER"
        let sheet = CellSheet(
            cells: [S.cell(1, "\(marker) 12,50 €", table: 0, row: 0, column: 0), S.cell(2, marker)],
            convention: .plain, readMs: 1)
        let prompt = PlanPrompt(instruction: "total", sheet: sheet, image: S.image, selection: nil)
        #expect(prompt.messages[1].content.contains(marker))
        let retry = PlanPrompt.retry(prompt, correction: PlanCorrection(reply: "{}", note: defect.correction))
        #expect(defect.isRetryable)
        #expect(retry.messages.last.map { !$0.content.contains(marker) } == true)
    }
}

// M14: the results block, the composed reply and the retry, byte for byte against `multi.py`'s model.

private typealias Item = MathFixtures.Item

private let fr = Locale(identifier: "fr_FR")

/// m01's two price columns, as the exact-cell listing numbers them.
private let m01Sheet = MathFixtures.sheet(
    ["12,99 €", "9,99 €", "17,49 €", "49,20 €"].enumerated().map {
        Item(id: "C\($0.offset + 1)", text: $0.element, table: 0, row: $0.offset + 1, column: 2)
    }
        + ["4,50 €", "3,20 €", "11,90 €", "6,75 €", "2,99 €"].enumerated().map {
            Item(id: "C\($0.offset + 5)", text: $0.element, table: 1, row: $0.offset + 1, column: 1)
        })
/// m04's net amounts.
private let m04Sheet = MathFixtures.sheet(
    ["120,00 €", "45,50 €", "310,00 €", "18,90 €", "76,35 €"].enumerated().map {
        Item(id: "C\($0.offset + 1)", text: $0.element, table: 0, row: $0.offset + 1, column: 1)
    })

private func entry(_ understood: String, _ formula: String, _ unit: String = "EUR") -> String {
    #"{"understood": "\#(understood)", "formula": "\#(formula)", "unit": "\#(unit)", "unit_label": ""}"#
}

/// The composed results of a reply over `sheet`, numbered from `first`.
private func composed(
    _ entries: [String], sheet: CellSheet, instruction: String, first: Int = 1, kept: [KeptResult] = []
) throws -> (results: [PlanPrompt.ComposedResult], outcomes: [ResultOutcome]) {
    let reply = #"{"results": [\#(entries.joined(separator: ", "))]}"#
    let plans = try PlanSet.decode(reply, finishReason: "stop").get().results
    let outcomes = try MathEngine.solveAll(
        reply: reply, finishReason: "stop", sheet: sheet, instruction: instruction, kept: kept
    ).get()
    let results = zip(plans, outcomes).enumerated().map { index, pair in
        PlanPrompt.ComposedResult(
            number: first + index, understood: pair.0.understood,
            answer: (try? pair.1.get()).map {
                ExactAnswer($0, sheet: sheet, policy: .standard, fallback: fr, kept: kept)
            })
    }
    return (results, outcomes)
}

private func keptResult(_ number: Int, _ value: String, _ understood: String, scale: Int = 2) -> KeptResult {
    KeptResult(
        number: number, value: Decimal(string: value) ?? .nan, unit: .money(.eur), unitLabel: nil, scale: scale,
        shown: value.replacingOccurrences(of: ".", with: ",") + "\u{00A0}€", understood: understood,
        turn: UtteranceID(1))
}

@Suite struct PlanPromptResultsTests {
    static let m01Question =
        "La somme de tous les prix par mois du premier tableau ainsi que tous les prix mensuels du deuxième."

    @Test func m01sComposedReplyIsTheModels() throws {
        let (results, _) = try composed(
            [
                entry("Le total du premier tableau.", "SUM(C1, C2, C3, C4)"),
                entry("Le total du deuxième tableau.", "SUM(C5, C6, C7, C8, C9)"),
            ], sheet: m01Sheet, instruction: Self.m01Question)
        #expect(
            PlanPrompt.composedReply(results)
                == "%% ① Le total du premier tableau. ② Le total du deuxième tableau.\n\n"
                + "① 12,99 € + 9,99 € + 17,49 € + 49,20 € =\n① 89,67\u{00A0}€\n"
                + "② 4,50 € + 3,20 € + 11,90 € + 6,75 € + 2,99 € =\n② 29,34\u{00A0}€")
    }

    @Test func m01sTurnAddsItsFormulasOnTheSameSheet() throws {
        let (results, _) = try composed(
            [
                entry("Le total du premier tableau.", "SUM(C1, C2, C3, C4)"),
                entry("Le total du deuxième tableau.", "SUM(C5, C6, C7, C8, C9)"),
            ], sheet: m01Sheet, instruction: Self.m01Question)
        let reply = PlanPrompt.composedReply(results)
        let turn = AskTurn(
            id: UtteranceID(1), instruction: Self.m01Question, reply: reply, region: PlanPromptThreadTests.region,
            sheet: m01Sheet, formula: "SUM(C1, C2, C3, C4)",
            formulas: ["SUM(C1, C2, C3, C4)", "SUM(C5, C6, C7, C8, C9)"],
            results: [keptResult(1, "89.67", "a"), keptResult(2, "29.34", "b")])
        let thread = AskThread(
            rootID: UtteranceID(1), kind: .assistant, selection: nil, pin: PlanPromptThreadTests.pin, turns: [turn])
        let images = [UtteranceID(1): PlanPromptThreadTests.image(1)]
        let same = try #require(
            PlanPrompt.thread(thread, current: ("encore", nil), sheet: m01Sheet, images: images))
        #expect(
            same.messages[2].content
                == reply + "\nFormula RES1: SUM(C1, C2, C3, C4)\nFormula RES2: SUM(C5, C6, C7, C8, C9)")
        let other = try #require(
            PlanPrompt.thread(thread, current: ("encore", nil), sheet: m04Sheet, images: images))
        #expect(other.messages[2].content == reply)
    }

    @Test func m04sFailedResultIsNotComputed() throws {
        let (results, _) = try composed(
            [
                entry("Le total HT.", "SUM(C1, C2, C3, C4, C5)"), entry("La TVA à 20 %.", "C9 * 20%"),
                entry("Le total TTC.", "SUM(C1, C2, C3, C4, C5) * 1.20"),
            ], sheet: m04Sheet, instruction: "Le total HT, la TVA à 20 % et le total TTC.")
        #expect(results[1].answer == nil)
        let third = try #require(results[2].answer?.working)
        // The model's working line for ③ is its own sketch (`multi.working`); Hark's is `WorkingLine`'s.
        #expect(
            PlanPrompt.composedReply(results)
                == "%% ① Le total HT. ② La TVA à 20 %. ③ Le total TTC.\n\n"
                + "① 120,00 € + 45,50 € + 310,00 € + 18,90 € + 76,35 € =\n① 570,75\u{00A0}€\n② not computed\n"
                + "③ \(third)\n③ 684,90\u{00A0}€")
    }

    @Test func oneResultIsTodaysReplyByteForByte() throws {
        let (results, outcomes) = try composed(
            [entry("Le total du premier tableau.", "SUM(C1, C2, C3, C4)")], sheet: m01Sheet,
            instruction: Self.m01Question)
        let today = ExactAnswer(try outcomes[0].get(), sheet: m01Sheet, policy: .standard, fallback: fr)
        #expect(PlanPrompt.composedReply(results) == today.reply)
        #expect(
            PlanPrompt.composedReply(results)
                == "%% Le total du premier tableau.\n\n12,99 € + 9,99 € + 17,49 € + 49,20 € =\n89,67\u{00A0}€")
    }

    @Test func m09sRequestCarriesTheResultsBlock() throws {
        let kept = [
            keptResult(1, "89.67", "Le total du premier tableau."),
            keptResult(2, "29.34", "Le \"deuxième\"\ntableau, " + String(repeating: "x", count: 90)),
        ]
        #expect(
            PlanPrompt.resultsBlock(kept) == [
                "", "Earlier results, computed by Hark:", #"RES1 = 89.67 EUR "Le total du premier tableau.""#,
                #"RES2 = 29.34 EUR "Le \"deuxième\"\ntableau, "#
                    + String(repeating: "x", count: 57) + "\"",
            ])
        let turn = AskTurn(
            id: UtteranceID(1), instruction: "q", reply: "%% ① a ② b\n\n① 1\n② 2", region: nil, sheet: m01Sheet,
            formulas: ["C1", "C2"], results: kept)
        let thread = AskThread(
            rootID: UtteranceID(1), kind: .assistant, selection: nil, pin: PlanPromptThreadTests.pin, turns: [turn])
        let prompt = try #require(
            PlanPrompt.thread(
                thread, current: ("Multiplie le résultat un par 12.", nil), sheet: m01Sheet, images: [:]))
        let last = try #require(prompt.messages.last?.content)
        let block = PlanPrompt.resultsBlock(kept).joined(separator: "\n")
        #expect(last.hasSuffix(PlanPrompt.listing(m01Sheet) + "\n" + block))
    }

    @Test func noBlockWithoutAKeptResult() {
        #expect(PlanPrompt.resultsBlock([]).isEmpty)
    }

    @Test func theFigureHasAPointTheShownDecimalsAndNoGrouping() {
        let average = KeptResult(
            number: 2, value: (Decimal(string: "157353.05") ?? 0) / 3, unit: .money(.usd), unitLabel: nil, scale: 2,
            shown: "$52,451.02", understood: "avg", turn: UtteranceID(1))
        let count = KeptResult(
            number: 3, value: 3, unit: .count, unitLabel: nil, scale: 0, shown: "3", understood: "n",
            turn: UtteranceID(1))
        let pct = KeptResult(
            number: 4, value: Decimal(string: "-12.5") ?? 0, unit: .percent, unitLabel: nil, scale: 2,
            shown: "−12,50 %", understood: "p", turn: UtteranceID(1))
        let even = keptResult(5, "1000", "e")
        #expect(
            PlanPrompt.resultsBlock([average, count, pct, even]).dropFirst(2) == [
                #"RES2 = 52451.02 USD "avg""#, #"RES3 = 3 count "n""#, #"RES4 = -12.50 percent "p""#,
                #"RES5 = 1000.00 EUR "e""#,
            ])
    }

    @Test func aReferenceIsWrittenAsItsNumberAndFigure() throws {
        let kept = [keptResult(1, "89.67", "a")]
        let (results, _) = try composed(
            [entry("Le résultat un fois douze.", "RES1 * 12")], sheet: m01Sheet,
            instruction: "Multiplie le résultat un par 12.", kept: kept)
        let answer = try #require(results[0].answer)
        #expect(answer.working == "① 89,67\u{00A0}€ × 12 =")
        #expect(answer.result == "1\u{202F}076,04\u{00A0}€")
    }

    @Test func oneEntrysRetryKeepsTodaysNote() {
        #expect(PlanPrompt.retryNote(.success([.failure(.plan(.unknownCell))])) == PlanDefect.unknownCell.correction)
        #expect(PlanPrompt.retryNote(.success([.failure(.plan(.noFormula))])) == nil)
        #expect(PlanPrompt.retryNote(.success([.failure(.math(.garbled, cell: nil))])) == nil)
    }

    @Test func severalEntriesAreRetriedByPosition() throws {
        let computed = try MathEngine.solve(
            reply: planReply("SUM(C1, C2)", unit: "EUR"), finishReason: "stop", sheet: m01Sheet, instruction: "x"
        ).get()
        let outcomes: [ResultOutcome] = [
            .success(computed), .failure(.plan(.unknownCell)), .failure(.plan(.unspokenConstant("4.5"))),
        ]
        #expect(
            PlanPrompt.retryNote(.success(outcomes))
                == "result 2: refer only to IDs from the item list; result 3: 4.5 is not a number the user said: "
                + "refer to its item. Keep the other results as they were")
        #expect(PlanPrompt.retryNote(.success([.success(computed), .failure(.math(.noNumber, cell: nil))])) == nil)
        #expect(PlanPrompt.retryNote(.success([.success(computed)])) == nil)
    }

    @Test func aWholeReplyDefectHasItsOwnNote() {
        #expect(
            PlanPrompt.retryNote(.failure(.plan(.json)))
                == "reply with one JSON object with a results array of 1 to 3 entries, each with understood, formula, "
                + "unit and unit_label only")
        #expect(PlanPrompt.retryNote(.failure(.plan(.truncated))) == nil)
        #expect(
            PlanPrompt.retryLine(PlanPrompt.retryNote(.failure(.plan(.json))) ?? "")
                .hasPrefix("Hark could not use that plan: reply with one JSON object with a results array"))
    }
}
