import Foundation
import HarkCore
import Testing

@Suite struct SpokenNumbersTests {
    @Test(arguments: [
        ("Split the bill four ways with an 18% tip", ["4", "18"]), ("partage en quatre", ["4"]),
        ("la moitié", ["2", "0.5"]), ("a third of it", ["3"]), ("a quarter", ["4", "0.25"]),
        ("vingt-cinq pour cent", ["25", "20", "5", "100"]), ("soixante et onze", ["71", "60", "11"]),
        ("quatre-vingt-dix", ["90"]), ("soixante-dix", ["70"]), ("twenty-five", ["25"]), ("a dozen", ["12"]),
        ("2,5 fois", ["2.5"]), ("1.5 times", ["1.5"]), ("12 %", ["12"]), ("ninety-nine", ["99"]),
        ("trois-cents", ["300", "3", "100"]), ("deux mille", ["2", "1000"]), ("twice", ["2"]),
    ])
    func spokenNumbersAreRead(_ instruction: String, _ expected: [String]) {
        let spoken = SpokenNumbers.spoken(in: instruction)
        for text in expected {
            let number = Decimal(string: text) ?? .nan
            #expect(spoken.contains { $0 == number }, "\(instruction) lacks \(text)")
        }
    }

    @Test func eachSpokenNumberBringsItsPercentForms() {
        let allowed = SpokenNumbers.allowed(in: "with an 18% tip")
        for text in ["18", "0.18", "1.18", "0.82", "0", "1", "100", "1000", "12", "52", "7", "24", "60", "365", "3600"]
        {
            let number = Decimal(string: text) ?? .nan
            #expect(allowed.contains { $0 == number }, "\(text)")
        }
    }

    @Test func aTranscriptWithNoNumberAllowsTheTableOnly() {
        #expect(SpokenNumbers.spoken(in: "How much did I pay?").isEmpty)
        #expect(SpokenNumbers.allowed(in: "How much did I pay?").count == SpokenNumbers.conversions.count + 2)
    }
}
