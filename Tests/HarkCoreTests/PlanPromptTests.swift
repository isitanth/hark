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
    @Test func theSystemIsTheFrozenPromptByteForByte() {
        let digest = SHA256.hash(data: Data(PlanPrompt.system.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "178eed0401e83b6ff561bc7b9da3340c6d414249238d3ff7bb91a228b3c30e8b")
        #expect(PlanPrompt.system.count == 2163)
        #expect(!PlanPrompt.system.hasSuffix("\n"))
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
        .unit("the result is an amount in CHF, which is not in the unit list: write none"), .degenerate,
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
