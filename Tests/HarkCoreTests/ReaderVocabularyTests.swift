import Foundation
import Testing

@testable import HarkCore

@Suite struct ReaderVocabularyTests {
    @Test(arguments: [
        "1 234,56 €", "1\u{00A0}234,56 €", "1\u{202F}234,56 €", "1,234.56", "(1 234,56)", "−48,90", "+2315,00",
        "£21.32", "85p", "7,5 h", "1,236 kg", "12 %", "1234", "123", "12345,6",
    ])
    func cleanNumbersAreAccepted(text: String) {
        #expect(ReaderVocabulary.isClean(text))
    }

    @Test(arguments: ["12,3,4", "€", "", "Mon 19", "6,54 A", "£21,32łł"])
    func otherTextsAreRefused(text: String) {
        #expect(!ReaderVocabulary.isClean(text))
    }

    @Test(arguments: ["€", "−", "–", "—", "•", "·", "’", "‘", "“", "”", "…", "›", "‹", "▾", "×", "→", "←", "°", "№"])
    func documentSymbolsAreNotSuspicious(symbol: String) {
        #expect(!ReaderVocabulary.isSuspicious("12 \(symbol)"))
    }

    @Test(arguments: ["ą", "ł", "ć", "ę", "š", "Ś", "З"])
    func strayLettersAreSuspicious(letter: String) {
        #expect(ReaderVocabulary.isSuspicious("12\(letter)"))
    }

    @Test(arguments: [("1 234,56 €", 2), ("12", 0), ("7,5 h", 1), ("(3,10)", 2), ("85p", 0)])
    func decimalsAreCounted(text: String, count: Int) {
        #expect(ReaderVocabulary.decimals(text) == count)
    }

    @Test(arguments: [("£21,32łł", "2132"), ("abc", ""), ("12ą34", "12")])
    func cleanPrefixStopsAtTheFirstSuspiciousCharacter(text: String, prefix: String) {
        #expect(ReaderVocabulary.cleanPrefix(text) == prefix)
    }

    @Test(arguments: [("З", "3"), ("з", "3"), ("О", "0"), ("о", "0"), ("O", "O"), ("1З,5О", "13,50")])
    func homoglyphsBecomeDigits(text: String, replaced: String) {
        #expect(ReaderVocabulary.replacingHomoglyphs(text) == replaced)
    }

    @Test(arguments: [
        ("3,79", Decimal(379) / 100), ("-0,50", Decimal(-5) / 10), ("1 234,56", Decimal(123_456) / 100),
        ("1,234", Decimal(1234) / 1000), ("7h30", Decimal(75) / 10), ("1,2k", Decimal(1200)),
        ("(12,00 €)", Decimal(-12)),
    ])
    func theFrenchParserReadsNumbers(text: String, value: Decimal) {
        #expect(ReaderVocabulary.frenchNumber(text) == value)
    }

    @Test func theFrenchParserFindsNoNumberInWords() {
        #expect(ReaderVocabulary.frenchNumber("abc") == nil)
    }

    @Test(
        arguments: [("3,79 A", "3,79"), (" 12,00 B ", "12,00"), ("3,79", nil), ("3,79 AB", nil)] as [(String, String?)]
    )
    func aCodeLetterFollowsItsNumber(text: String, number: String?) {
        #expect(ReaderVocabulary.numberAndCode(text) == number)
    }

    @Test func theLadderIsV2Fs() {
        #expect(Rung.ladder.map(\.description) == ["accurate 2x", "accurate 3x", "accurate 1x", "fast 2x"])
        #expect(Rung.ladder.allSatisfy { $0.pad == 6 })
    }
}
