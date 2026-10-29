import Foundation
import HarkCore
import Testing

private func vote(_ texts: [String]) -> NumberConvention {
    DisplayedNumber.convention(of: texts.map { ColumnText(text: $0, table: 0, column: 0) })
}

@Suite struct NumberConventionTests {
    @Test func aFrenchRegion() {
        let convention = vote(["1\u{202F}234,56\u{00A0}€", "12,50\u{00A0}€", "−3,00\u{00A0}€", "20\u{202F}%"])
        #expect(convention.decimalSeparator == ",")
        #expect(convention.groupingSeparator == "\u{202F}")
        #expect(convention.currencySymbol == "€")
        #expect(convention.symbolAfter)
        #expect(convention.minus == "−")
        #expect(convention.currencySpacing == "\u{00A0}")
        #expect(convention.percentSpacing == "\u{202F}")
    }

    @Test func anAmericanRegion() {
        let convention = vote(["$1,234.56", "$12.50", "-$3.00", "4.5%"])
        #expect(convention.decimalSeparator == ".")
        #expect(convention.groupingSeparator == ",")
        #expect(convention.currencySymbol == "$")
        #expect(!convention.symbolAfter)
        #expect(convention.minus == "-")
        #expect(convention.percentSpacing == nil)
    }

    @Test func aBritishRegion() {
        let convention = vote(["£2,418.62", "£21.30", "£0.99"])
        #expect(convention.decimalSeparator == ".")
        #expect(convention.groupingSeparator == ",")
        #expect(convention.currencySymbol == "£")
    }

    @Test func aSwissRegion() {
        let convention = vote(["CHF 1'234.50", "CHF 12.40", "2'480.00"])
        #expect(convention.decimalSeparator == ".")
        #expect(convention.groupingSeparator == "'")
        #expect(convention.currencySymbol == "CHF")
    }

    @Test func aGermanRegion() {
        let convention = vote(["1.234,56 €", "12,50 €", "3.400,00 €"])
        #expect(convention.decimalSeparator == ",")
        #expect(convention.groupingSeparator == ".")
    }

    @Test func onlyAmbiguousNumbersFallBackOnTheCurrency() {
        #expect(vote(["1,234 €", "2,480 €"]).decimalSeparator == ",")
        #expect(vote(["$1,234", "$2,480"]).decimalSeparator == ".")
        #expect(vote(["1,234", "2,480"]) == NumberConvention(decimalSeparator: "."))
    }

    @Test func onlyAmbiguousNumbersAndNoCurrencyTakeTheMacsSeparatorWithANote() throws {
        let context = ReadingContext(macDecimal: ",")
        guard case .amount(let amount) = DisplayedNumber.read("1,234", context: context) else {
            Issue.record("no amount")
            return
        }
        #expect(amount.value == Decimal(string: "1.234"))
        #expect(amount.notes.contains(.assumedConvention))
    }

    @Test func aColumnOverridesTheRegion() throws {
        let region = vote(["12,50 €", "3,20 €", "1,234"])
        #expect(region.decimalSeparator == ",")
        let column = DisplayedNumber.decimalVote(["1,234", "2.50", "3.75"])
        #expect(column == ".")
        let context = ReadingContext(columnDecimal: column, region: region)
        guard case .amount(let amount) = DisplayedNumber.read("1,234", context: context) else {
            Issue.record("no amount")
            return
        }
        #expect(amount.value == 1234)
    }

    @Test func aTieKeepsNoVote() {
        #expect(DisplayedNumber.decimalVote(["1,5", "2.5"]) == nil)
        #expect(DisplayedNumber.decimalVote([]) == nil)
    }
}
