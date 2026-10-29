import Foundation
import HarkCore
import Testing

private func dec(_ text: String) -> Decimal {
    DisplayedNumber.parse(text, convention: .plain) ?? .nan
}

private func amount(_ text: String, _ context: ReadingContext = ReadingContext()) -> Amount? {
    guard case .amount(let amount) = DisplayedNumber.read(text, context: context) else { return nil }
    return amount
}

private let table = ReadingContext(inTable: true, columnHoldsAmounts: true)

@Suite struct DisplayedNumberTests {
    @Test(
        arguments: [
            ("$1,234.56", "1234.56", "USD"), ("£1,234.56", "1234.56", "GBP"), ("1 234,56 €", "1234.56", "EUR"),
            ("1\u{00A0}234,56 €", "1234.56", "EUR"), ("1\u{202F}234,56 €", "1234.56", "EUR"),
            ("1\u{2009}234,56 €", "1234.56", "EUR"), ("1\u{2007}234,56 €", "1234.56", "EUR"),
            ("1'234.56", "1234.56", nil), ("1’234.56", "1234.56", nil), ("1.234,56 €", "1234.56", "EUR"),
            ("€1,234.56", "1234.56", "EUR"), ("EUR 1 234,56", "1234.56", "EUR"), ("1234,56EUR", "1234.56", "EUR"),
            ("１２３", "123", nil), ("CHF 1'234.50", "1234.50", "CHF"),
        ] as [(String, String, String?)])
    func formats(_ text: String, _ value: String, _ currency: String?) throws {
        let read = try #require(amount(text))
        #expect(read.value == Decimal(string: value))
        if let currency {
            #expect(read.unit == .money(try #require(Currency.code(currency))))
        } else {
            #expect(read.unit == .number)
        }
    }

    @Test(arguments: [
        ("-12", "-12"), ("−12", "-12"), ("–12", "-12"), ("‒12", "-12"), ("﹣12", "-12"), ("－12", "-12"),
        ("-€12", "-12"), ("€-12", "-12"), ("− 12,00 €", "-12"), ("+12,00 €", "12"), ("(1,234.56)", "-1234.56"),
        ("(€62.50)", "-62.5"), ("€(62.50)", "-62.5"), ("($1,240.10)", "-1240.1"), ("(129,99)", "-129.99"),
        ("(212)", "212"), ("−0,00", "0"),
    ])
    func signs(_ text: String, _ value: String) throws {
        #expect(try #require(amount(text)).value == Decimal(string: value))
    }

    @Test func aTrailingMinusIsNegativeInATableCellOnly() throws {
        #expect(try #require(amount("48.90-", ReadingContext(inTable: true))).value == Decimal(string: "-48.90"))
        #expect(try #require(amount("48.90-")).value == Decimal(string: "48.90"))
    }

    @Test func parenthesesAroundABareIntegerAreNegativeInASignedColumnOnly() throws {
        let alone = try #require(amount("(212)"))
        #expect(alone.value == 212)
        #expect(alone.notes.contains(.parenthesized))
        let signed = ReadingContext(inTable: true, columnHoldsAmounts: true, columnSigned: true)
        #expect(try #require(amount("(1,240)", signed)).value == -1240)
    }

    @Test(
        arguments: [
            ("85p", "0.85", "GBP", 2), ("99c", "0.99", "USD", 2), ("99¢", "0.99", "USD", 2), ("50 ct", "0.5", "EUR", 2),
        ] as [(String, String, String, Int)])
    func minorUnits(_ text: String, _ value: String, _ code: String, _ scale: Int) throws {
        let read = try #require(amount(text))
        #expect(read.value == Decimal(string: value))
        #expect(read.unit == .money(try #require(Currency.code(code))))
        #expect(read.scale == scale)
        #expect(read.notes.contains(.pence))
    }

    @Test(
        arguments: [
            ("20 %", "20", CellUnit.percent), ("20%", "20", .percent), ("−3,5 %", "-3.5", .percent),
            ("1.2k", "1200", .number), ("3,4 M€", "3400000", .money(.eur)), ("£3.4m", "3400000", .money(.gbp)),
            ("2 Md€", "2000000000", .money(.eur)), ("1.5bn", "1500000000", .number), ("5 m", "5", .number),
            ("7h30", "7.5", .hours), ("7 h 30", "7.5", .hours), ("4.5 h", "4.5", .hours), ("400g", "400", .number),
            ("412 kWh", "412", .number), ("12 jours", "12", .number),
        ] as [(String, String, CellUnit)])
    func units(_ text: String, _ value: String, _ unit: CellUnit) throws {
        let read = try #require(amount(text))
        #expect(read.value == Decimal(string: value))
        #expect(read.unit == unit)
    }

    @Test func scaleWordsAreApproximate() throws {
        #expect(try #require(amount("1.2k")).notes.contains(.approximate))
        #expect(try #require(amount("~ 12")).notes.contains(.approximate))
        #expect(try #require(amount("12")).notes.isEmpty)
    }

    @Test(arguments: [
        "Q3", "T1", "C12", "A4", "#10495", "n°3", "1er", "3rd", "02/10", "16/11/2026", "2026-10-26", "Oct 2", "2 oct.",
        "11:52 AM", "8–9am", "7:30", "Q1 2026", "Octobre 2026", "10.01.2026", "", "—", "n/a", "Total", "З",
        "FA-2026-0412", "4970 1234 5678 9012",
    ])
    func notAmounts(_ text: String) {
        #expect(DisplayedNumber.read(text, context: ReadingContext()) == .text)
    }

    @Test(arguments: [("2026", "2026"), ("10.01", "10.01")])
    func numbersThatLookLikeDates(_ text: String, _ value: String) {
        #expect(dec(text) == Decimal(string: value))
    }

    @Test(arguments: ["—", "–", "-", "−"])
    func aLoneDashInAnAmountsColumnIsZero(_ dash: String) throws {
        let read = try #require(amount(dash, table))
        #expect(read.value == 0)
        #expect(read.notes == [.dashAsZero])
    }

    @Test(arguments: ["£2,418.6ąłą", "£21,32łł", "1,275.5łął", "1O5,00"])
    func gluedJunkIsGarbled(_ text: String) {
        #expect(DisplayedNumber.read(text, context: ReadingContext(currency: .gbp)) == .garbled)
    }

    @Test func completeDigitsBeforeJunkAreADoubt() throws {
        let read = try #require(amount("1,915.35ą", ReadingContext(currency: .usd)))
        #expect(read.value == Decimal(string: "1915.35"))
        #expect(read.notes.contains(.doubt))
        #expect(DisplayedNumber.read("1,915.35ą", context: ReadingContext()) == .garbled)
    }

    @Test(arguments: [
        ("12,5", "12.5"), ("0,123", "0.123"), ("3.1416", "3.1416"), ("1,234,567", "1234567"),
        ("1.234.567,89", "1234567.89"),
    ])
    func separatorsTheTokenDecides(_ text: String, _ value: String) {
        let result = DisplayedNumber.reading(text, context: ReadingContext())
        guard case .amount(let read) = result.reading else {
            Issue.record("no amount in \(text)")
            return
        }
        #expect(read.value == Decimal(string: value))
        #expect(result.step == .token)
    }

    @Test func aRepeatedMarkBeforeAShortGroupIsNoAmount() {
        #expect(DisplayedNumber.read("1.234.5", context: ReadingContext()) == .text)
    }

    @Test(
        arguments: [
            ("£18,450", ReadingContext(), "18450", SeparatorStep.currencyMinorUnits),
            (
                "1,234", ReadingContext(columnDecimal: ",", region: NumberConvention(decimalSeparator: ".")), "1.234",
                .column
            ),
            ("1,236 kg", ReadingContext(region: NumberConvention(decimalSeparator: ",")), "1.236", .region),
            ("1,859 €/L", ReadingContext(region: NumberConvention(decimalSeparator: ",")), "1.859", .region),
            ("1,859 €/L", ReadingContext(), "1.859", .currency), ("$3.459/gal", ReadingContext(), "3.459", .currency),
            ("1.234", ReadingContext(currency: .eur), "1234", .currency),
            ("1,234", ReadingContext(macDecimal: ","), "1.234", .macLocale),
            ("1,234", ReadingContext(macDecimal: "."), "1234", .macLocale),
        ] as [(String, ReadingContext, String, SeparatorStep)])
    func ambiguousMarksAreDecidedStepByStep(
        _ text: String, _ context: ReadingContext, _ value: String, _ step: SeparatorStep
    ) throws {
        let result = DisplayedNumber.reading(text, context: context)
        guard case .amount(let read) = result.reading else {
            Issue.record("no amount in \(text)")
            return
        }
        #expect(read.value == Decimal(string: value))
        #expect(result.step == step)
        #expect(read.notes.contains(.assumedConvention) == (step == .currency || step == .macLocale))
    }

    @Test func aReceiptsCommaDecimalsDecideItsKilos() {
        let sheet = MathFixtures.sheet(texts: ["2,49", "6,54", "1,236 kg"])
        #expect(sheet.convention.decimalSeparator == ",")
        #expect(
            sheet.cells[2].reading == .amount(Amount(value: Decimal(string: "1.236") ?? 0, unit: .number, scale: 3)))
    }

    @Test func thirtyEightDigitsAreExactAndThirtyNineAreRefused() throws {
        let digits38 = String(repeating: "9", count: 38)
        #expect(try #require(amount(digits38)).value.description == digits38)
        #expect(DisplayedNumber.read(digits38 + "9", context: ReadingContext()) == .text)
    }

    @Test(arguments: [
        ("£2.69 Was £2.99", ["£2.69", "Was £2.99"]), ("6 x 1,09", ["6", "x 1,09"]), ("7 £23.40", ["7", "£23.40"]),
        ("Courses\n420,00 €\n486,35 €", ["Courses 420,00 €", "486,35 €"]), ("5,10 € 4,59 €", ["5,10 €", "4,59 €"]),
        ("Total 62,40 €", ["Total 62,40 €"]),
    ])
    func severalAmountsSplit(_ text: String, _ parts: [String]) {
        #expect(DisplayedNumber.split(text) == parts)
    }

    @Test func twoAmountsUnsplitReadAsText() {
        #expect(DisplayedNumber.read("£2.69 Was £2.99", context: ReadingContext()) == .text)
    }

    /// One ID, one number: the frozen `harness.split_amounts` on every item text of the 28 cases' readings.
    @Test(arguments: MathFixtures.split)
    func theSplitMatchesTheFrozenHarness(_ row: MathFixtures.SplitRow) {
        #expect(DisplayedNumber.split(row.text) == row.parts)
    }

    @Test func theFixtureIsThere() {
        #expect(MathFixtures.split.count > 1000)
    }
}
