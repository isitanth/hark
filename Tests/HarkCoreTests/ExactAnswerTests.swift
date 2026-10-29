import Foundation
import HarkCore
import Testing

private func answer(
    _ formula: String, _ texts: [String], unit: String = "none", instruction: String = "Total?",
    understood: String = "You want the total.", locale: String = "en_US"
) throws -> ExactAnswer {
    let sheet = MathFixtures.sheet(texts: texts)
    let computation = try MathEngine.solve(
        reply: planReply(formula, unit: unit, understood: understood), finishReason: "stop", sheet: sheet,
        instruction: instruction
    ).get()
    return ExactAnswer(computation, sheet: sheet, policy: .standard, fallback: Locale(identifier: locale))
}

/// ICU's spaces move with the OS: compare with every no-break space as a plain one.
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        .replacingOccurrences(of: "\u{2019}", with: "'")
}

@Suite struct ExactAnswerTests {
    @Test func theReplyKeepsTheResultAloneOnItsLastLine() throws {
        let exact = try answer("SUM(C1, C2)", ["$145.00", "$99.00"])
        #expect(exact.reply == "%% You want the total.\n\n$145.00 + $99.00 =\n$244.00")
        let split = IntentSplit.split(exact.reply, complete: true)
        #expect(split.intent == "You want the total.")
        #expect(split.answer == "$145.00 + $99.00 =\n$244.00")
        #expect(split.answer.split(separator: "\n").last.map(String.init) == exact.result)
    }

    @Test func withNoWorkingLineTheResultFollowsTheBlankLine() throws {
        let exact = try answer("COUNT(C1, C2)", ["a", "b"])
        #expect(exact.working == nil)
        #expect(exact.reply == "%% You want the total.\n\n2")
    }

    @Test(arguments: [
        ("en_US", "$1,234.50"), ("fr_FR", "1 234,50 $US"), ("en_GB", "US$1,234.50"), ("de_CH", "$ 1'234.50"),
    ])
    func theResultIsInTheUsersFormat(_ locale: String, _ expected: String) throws {
        let exact = try answer("C1", ["$1,234.50"], locale: locale)
        #expect(plain(exact.result) == plain(expected))
    }

    @Test func euroResultsInFrenchAndAmerican() throws {
        #expect(plain(try answer("C1 + C2", ["12,50 €", "1 000,00 €"], locale: "fr_FR").result) == "1 012,50 €")
        #expect(try answer("C1 + C2", ["12,50 €", "1 000,00 €"], locale: "en_US").result == "€1,012.50")
    }

    @Test(arguments: [
        (["1 234,56 €", "12,50 €"], "1 234,56 € + 12,50 € ="), (["$1,234.56", "$12.50"], "$1,234.56 + $12.50 ="),
        (["£1,234.56", "£12.50"], "£1,234.56 + £12.50 ="),
        (["CHF 1'234.56", "CHF 12.50"], "CHF 1'234.56 + CHF 12.50 ="),
    ])
    func theWorkingIsInTheDocumentsFormat(_ texts: [String], _ expected: String) throws {
        #expect(try answer("C1 + C2", texts).working == expected)
    }

    @Test func theDocumentsMinusAndSpacesAreKept() throws {
        let texts = ["145,00\u{00A0}€", "−62,50\u{00A0}€", "99,00\u{00A0}€"]
        let exact = try answer("SUM(C1, C2, C3)", texts, locale: "fr_FR")
        #expect(
            exact.working == "145,00\u{00A0}€ + 99,00\u{00A0}€".replacingOccurrences(
                of: " + 99", with: " − 62,50\u{00A0}€ + 99") + " =")
    }

    @Test(arguments: [
        ("AVG(C1, C2, C3)", ["10,00 €", "20,00 €", "30,00 €"], "(10,00 € + 20,00 € + 30,00 €) / 3 ="),
        ("MIN(C1, C2)", ["10,00 €", "20,00 €"], "MIN(10,00 € ; 20,00 €) ="),
        ("MIN(C1, C2)", ["$10.00", "$20.00"], "MIN($10.00, $20.00) ="),
        ("C1 * 1.18 / 4", ["10,00 €", "1,50 €"], "10,00 € × 1,18 / 4 ="),
        ("(C1 - C2) / C2 * 100", ["$120.00", "$100.00"], "($120.00 - $100.00) / $100.00 × 100 ="),
    ])
    func theWorkingShapes(_ formula: String, _ texts: [String], _ expected: String) throws {
        #expect(try answer(formula, texts, instruction: "split four ways, 18 % tip").working == expected)
    }

    @Test func twelveTermsHaveAWorkingLineAndThirteenDoNot() throws {
        let texts = (1...13).map { "\($0),00 €" }
        let twelve = "SUM(" + (1...12).map { "C\($0)" }.joined(separator: ", ") + ")"
        let thirteen = "SUM(" + (1...13).map { "C\($0)" }.joined(separator: ", ") + ")"
        #expect(try answer(twelve, texts).working != nil)
        #expect(try answer(thirteen, texts).working == nil)
    }

    @Test func aPickNamesItsRow() throws {
        let exact = try answer("ARGMIN(C1 @ C2, C3 @ C4)", ["£2.69", "1500g", "£1.79", "400g"], locale: "en_GB")
        #expect(exact.result == "400g — £1.79")
    }

    @Test func exactShowsOnlyWhenRoundingChangedTheValue() throws {
        let rounded = try answer("C1 / 4", ["$189.39"], instruction: "four ways")
        #expect(rounded.result == "$47.35")
        #expect(rounded.exact == "$47.3475")
        #expect(try answer("C1 / 4", ["$189.40"], instruction: "four ways").exact == nil)
    }

    @Test func aPercentResult() throws {
        let exact = try answer("(C1 - C2) / C2 * 100", ["120 €", "100 €"], unit: "percent", locale: "en_US")
        #expect(exact.result == "20.00%")
    }

    @Test func figuresNameTheirSource() throws {
        let exact = try answer(
            "SUM(C1, C2) * 1.12", ["145,00 €", "99,00 €"], instruction: "with 12 % more",
            understood: "You want 145,00 € and 99,00 € in 2026 for the 6 rows, plus 12 %, about 731,10 €.")
        #expect(
            exact.figures == [
                UnderstoodFigure(text: "145,00 €", source: .cell(CellID(1))),
                UnderstoodFigure(text: "99,00 €", source: .cell(CellID(2))),
                UnderstoodFigure(text: "12 %", source: .spoken),
                UnderstoodFigure(text: "731,10 €", source: .nowhere),
            ])
        #expect(exact.understood != nil)
    }

    /// A figure inside a longer number, or the same value in another unit, is not on screen: the check line shows.
    @Test func aFigureIsOnACellOnlyWholeAndInItsUnit() throws {
        let exact = try answer(
            "C1 + C2", ["11 200 €", "12 €"], instruction: "total",
            understood: "You want 1 200 € and 12 % of it, with 11 200 € and 12 € as read.")
        #expect(
            exact.figures == [
                UnderstoodFigure(text: "1 200 €", source: .nowhere),
                UnderstoodFigure(text: "12 %", source: .nowhere),
                UnderstoodFigure(text: "11 200 €", source: .cell(CellID(1))),
                UnderstoodFigure(text: "12 €", source: .cell(CellID(2))),
            ])
    }
}
