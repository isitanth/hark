import Foundation
import HarkCore
import Testing

private let policy = RoundingPolicy.standard
private let empty = CellSheet(cells: [], convention: .plain, readMs: 0)

private func shown(_ value: String, _ unit: MathUnit, texts: [String] = []) -> Decimal {
    let sheet = texts.isEmpty ? empty : MathFixtures.sheet(texts: texts)
    let read = sheet.cells.map(\.id)
    return policy.round(Decimal(string: value) ?? .nan, unit: unit, read: read, sheet: sheet)
}

@Suite struct RoundingPolicyTests {
    @Test(
        arguments: [
            ("47.3475", MathUnit.money(.eur), "47.35"), ("47.345", .money(.gbp), "47.35"),
            ("-47.345", .money(.eur), "-47.35"),
            ("1234.5", .money(.jpy), "1235"), ("1.23456", .money(try! #require(Currency.code("BHD"))), "1.235"),
            ("30.5607980587", .percent, "30.56"), ("23.505", .hours, "23.51"), ("6", .count, "6"),
            ("2.5", .count, "2.5"),
        ] as [(String, MathUnit, String)])
    func theDefaults(_ value: String, _ unit: MathUnit, _ expected: String) {
        #expect(shown(value, unit) == Decimal(string: expected))
    }

    @Test func aNumberTakesTheMostDecimalsAmongTheCellsReadAndAtLeastTwo() {
        #expect(policy.decimals(for: .number, read: [], sheet: empty)! == (2, 0))
        let sheet = MathFixtures.sheet(texts: ["13,5", "12,25", "4"])
        #expect(policy.decimals(for: .number, read: sheet.cells.map(\.id), sheet: sheet)! == (2, 2))
        let thousandths = MathFixtures.sheet(texts: ["1.236", "2"])
        #expect(policy.decimals(for: .number, read: thousandths.cells.map(\.id), sheet: thousandths)! == (3, 3))
        #expect(shown("13.8125", .number, texts: ["13,5", "12,25"]) == Decimal(string: "13.81"))
    }

    @Test func aCountIsExact() {
        #expect(policy.decimals(for: .count, read: [], sheet: empty) == nil)
        #expect(RoundingPolicy.displayUnit(.count, declared: .count, value: Decimal(string: "2.5")!) == .number)
        #expect(RoundingPolicy.displayUnit(.number, declared: .count, value: 6) == .count)
    }

    @Test func roundingHappensOnceAfterTheSnap() {
        let third = Decimal(1) / 3 * 3
        #expect(shown("\(third)", .money(.eur)) == 1)
        let inner = RoundingPolicy.round(Decimal(string: "2.345")!, scale: 2, rule: .halfUp)
        #expect(shown("\(inner)", .money(.eur)) == Decimal(string: "2.35"))
    }

    @Test(arguments: [
        (RoundingPolicy.Rule.halfUp, "2.345", "2.35"), (.halfUp, "-2.345", "-2.35"), (.halfEven, "2.345", "2.34"),
        (.down, "2.349", "2.34"),
    ])
    func eachRule(_ rule: RoundingPolicy.Rule, _ value: String, _ expected: String) {
        #expect(RoundingPolicy.round(Decimal(string: value)!, scale: 2, rule: rule) == Decimal(string: expected))
    }

    @Test(arguments: Currency.table)
    func theCurrencyTableMatchesNumberFormatter(_ currency: Currency) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.code
        #expect(formatter.maximumFractionDigits == currency.minorUnits, "\(currency.code)")
    }

    @Test func dollarsAndYenFollowTheRegion() {
        #expect(Currency.named("$") == .usd)
        #expect(Currency.named("¥") == .jpy)
        #expect(Currency.named("CAD") == .cad)
        #expect(Currency.named("ZZZ") == nil)
        guard case .amount(let amount) = DisplayedNumber.read("$12.50", context: ReadingContext(currency: .cad)) else {
            Issue.record("no amount")
            return
        }
        #expect(amount.unit == .money(.cad))
    }
}
