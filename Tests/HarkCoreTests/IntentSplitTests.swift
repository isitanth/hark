import HarkCore
import Testing

struct IntentSplitCase: Sendable, CustomTestStringConvertible {
    let number: Int
    let text: String
    let complete: Bool
    let intent: String?
    let answer: String
    var testDescription: String { "\(number)\(complete ? "" : " streaming")" }
}

/// The twelve cases of report a6, §2, case 10 both ways.
@Suite struct IntentSplitTests {
    static let cases: [IntentSplitCase] = [
        .init(
            number: 1, text: "La somme est 802,42 €.", complete: true, intent: nil, answer: "La somme est 802,42 €."),
        .init(number: 2, text: "%% Tu veux le total", complete: false, intent: "Tu veux le total", answer: ""),
        .init(
            number: 3, text: "%% Tu veux le total payé en 2026.\n\nTotal : 802,42 €", complete: true,
            intent: "Tu veux le total payé en 2026.", answer: "Total : 802,42 €"),
        .init(
            number: 4, text: "%% You want the net total.\r\n\r\nNet: €802.42", complete: true,
            intent: "You want the net total.", answer: "Net: €802.42"),
        .init(number: 5, text: "\u{FEFF}  \n%% Tu veux X.\n\nY", complete: true, intent: "Tu veux X.", answer: "Y"),
        .init(
            number: 6, text: "Voici le total.\n\n%% pas une intention", complete: true, intent: nil,
            answer: "Voici le total.\n\n%% pas une intention"),
        .init(
            number: 7, text: "%% Tu veux ce que tu as vraiment payé,\nen comptant les avoirs.\n\nRéponse",
            complete: true, intent: "Tu veux ce que tu as vraiment payé, en comptant les avoirs.", answer: "Réponse"),
        .init(
            number: 8, text: "%% " + String(repeating: "a", count: 300) + "\n\nOK", complete: true,
            intent: String(repeating: "a", count: 239) + "…", answer: "OK"),
        .init(
            number: 9, text: "%% Tu veux le total.\nTotal : 802,42 €", complete: true, intent: "Tu veux le total.",
            answer: "Total : 802,42 €"),
        .init(number: 10, text: "%", complete: false, intent: nil, answer: ""),
        .init(number: 10, text: "%", complete: true, intent: nil, answer: "%"),
        .init(number: 11, text: "%%\n\nRéponse seule", complete: true, intent: nil, answer: "Réponse seule"),
        .init(
            number: 12, text: "%% Tu veux le total.\nTotal : 802,42 €\nDétail", complete: false,
            intent: "Tu veux le total.", answer: "Total : 802,42 €\nDétail"),
    ]

    @Test(arguments: cases) func splits(_ c: IntentSplitCase) {
        let split = IntentSplit.split(c.text, complete: c.complete)
        #expect(split.intent == c.intent)
        #expect(split.answer == c.answer)
    }

    /// Case 9 while streaming: the answer's first line stays in the intent until the end or a second line break.
    @Test func caseNineStreamingHoldsTheFirstLineBack() {
        let split = IntentSplit.split("%% Tu veux le total.\nTotal : 802,42 €", complete: false)
        #expect(split.intent == "Tu veux le total. Total : 802,42 €")
        #expect(split.answer == "")
    }

    @Test func pastSixHundredCharactersTheIntentIsSettled() {
        let long = "%% " + String(repeating: "b", count: 601) + "\nsuite"
        let split = IntentSplit.split(long, complete: false)
        #expect(split.intent == String(repeating: "b", count: 239) + "…")
        #expect(split.answer == "suite")
    }

    @Test func anEmptyReplyIsNothing() {
        #expect(IntentSplit.split("", complete: true) == (nil, ""))
        #expect(IntentSplit.split(" \n\t", complete: false) == (nil, ""))
    }
}
