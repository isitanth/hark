import Foundation
import HarkCore
import Testing

/// Written by hand: oMLX's chunks and Claude's `text_delta`s, joined, for a plan with escapes in `understood`.
private let openAIReply =
    #"{"understood": "Vous voulez le total des factures \"payées\" à régler 💶, l'avoir déduit.\nC'est tout \\ fin.", "formula": "SUM(C7, C11)", "unit": "EUR"}"#
private let anthropicReply =
    "{\n  \"understood\": \"You want the paid invoices; the refunded one is left out.\",\n  \"formula\": \"SUM(C7, C11) - ABS(C15)\",\n  \"unit\": \"USD\"\n}"
private let openAIValue = "Vous voulez le total des factures \"payées\" à régler 💶, l'avoir déduit.\nC'est tout \\ fin."
private let anthropicValue = "You want the paid invoices; the refunded one is left out."
/// 0.1.0's schema: `unit_label` last, `understood` still first.
private let labelledReply =
    #"{"understood": "Vous voulez la somme du stockage des quatre classes.", "formula": "SUM(C4, C8, C12, C16)", "unit": "none", "unit_label": "To"}"#
private let labelledValue = "Vous voulez la somme du stockage des quatre classes."

/// Today's flat object read as a plan of one: its one `understood`, nil until its opening quote.
private func flat(_ partial: String) -> String? {
    PlanStream.understoods(partial: partial).first
}

@Suite struct PlanStreamTests {
    @Test(arguments: [(openAIReply, openAIValue), (anthropicReply, anthropicValue), (labelledReply, labelledValue)])
    func everyCutGivesAPrefixOfTheFinalValue(_ reply: String, _ value: String) {
        var last = ""
        var started = false
        for count in 0...reply.count {
            let shown = flat(String(reply.prefix(count)))
            if let shown {
                started = true
                #expect(value.hasPrefix(shown), "cut at \(count): \(shown)")
                #expect(shown.count >= last.count)
                last = shown
            } else {
                #expect(!started, "the line vanished at \(count)")
            }
        }
        #expect(last == value)
        #expect(flat(reply) == value)
    }

    @Test func nilUntilTheOpeningQuote() {
        #expect(flat("") == nil)
        #expect(flat("{\"underst") == nil)
        #expect(flat("{\"understood\": ") == nil)
        #expect(flat("{\"understood\": \"") == "")
    }

    @Test func aFormulaFirstStillShowsItsUnderstoodLater() {
        let reply = #"{"formula": "SUM(C1, C2)", "unit": "EUR", "understood": "You want the total."}"#
        #expect(flat(String(reply.prefix(30))) == nil)
        #expect(flat(reply) == "You want the total.")
    }

    @Test func aFencedReplyAndABOM() {
        #expect(flat("```json\n{\"understood\": \"Total") == "Total")
        #expect(flat("\u{FEFF} {\"understood\": \"Total\"") == "Total")
    }

    @Test func aKeyInsideAStringNeverMatches() {
        let reply = #"{"formula": "the \"understood\": \"no\" trap", "understood": "yes"}"#
        #expect(flat(reply) == "yes")
        #expect(flat(String(reply.prefix(40))) == nil)
    }

    @Test func anEmptyValueAndNoUnderstoodAtAll() {
        #expect(flat(#"{"understood": "", "formula": "C1""#) == "")
        #expect(flat(#"{"formula": "C1", "unit": "EUR"}"#) == nil)
        #expect(flat("not json") == nil)
    }

    @Test func aLongValueStreamsWhole() {
        let value = String(repeating: "abcdé ", count: 100)
        #expect(value.count == 600)
        #expect(flat("{\"understood\": \"\(value)\", \"formula\": \"C1\"}") == value)
    }

    @Test func neverAnythingOfTheFormulaOrTheUnit() {
        for count in 0...anthropicReply.count {
            let shown = flat(String(anthropicReply.prefix(count))) ?? ""
            #expect(!shown.contains("SUM") && !shown.contains("USD"))
        }
    }
}

// M14: each result's `understood`, c2a §4.2's partial states.

private let first = "Vous voulez le total du premier tableau."
private let setReply = """
    {"results": [{"understood": "\(first)", "formula": "SUM(C1, C2)", "unit": "EUR", "unit_label": ""}, \
    {"understood": "Et le total du second.", "formula": "SUM(C3, C4)", "unit": "EUR", "unit_label": ""}]}
    """

private func understoods(_ partial: String) -> [String] {
    PlanStream.understoods(partial: partial)
}

@Suite struct PlanStreamResultsTests {
    @Test(arguments: [
        "", "\u{FEFF}", "```json", "{", #"{"res"#, #"{"results""#, #"{"results":"#, #"{"results": ["#,
        #"{"results": [{"#, #"{"results": [{"underst"#, #"{"results": [{"understood""#,
        #"{"results": [{"understood": "#, #"{"results": "x"}"#, #"{"results": [{"formula": "C1""#,
    ])
    func nothingIsReachedYet(_ partial: String) {
        #expect(understoods(partial).isEmpty)
    }

    @Test func theFirstUnderstoodShowsAsItStreams() {
        #expect(understoods(#"{"results": [{"understood": "Vous vou"#) == ["Vous vou"])
        #expect(understoods(#"{"results": [{"understood": ""#) == [""])
    }

    @Test func aCutFormulaKeepsTheFirst() {
        #expect(understoods(#"{"results": [{"understood": "\#(first)", "formula": "SUM(C1"#) == [first])
    }

    @Test func aSecondItemOpenedKeepsTheFirst() {
        let partial = #"{"results": [{"understood": "\#(first)", "formula": "C1", "unit": "EUR"}, {"#
        #expect(understoods(partial) == [first])
    }

    @Test func theSecondUnderstoodShowsCut() {
        let opened = #"{"results": [{"understood": "\#(first)", "formula": "C1", "unit": "EUR"}, "#
        let partial = opened + #"{"understood": "Et le"#
        #expect(understoods(partial) == [first, "Et le"])
    }

    @Test(arguments: [#"Et le \u00e"#, #"Et le \"#, #"Et le \ud83d"#, #"Et le \ud83d\udc"#])
    func aCutEscapeIsHeldBack(_ tail: String) {
        let partial = #"{"results": [{"understood": "a", "formula": "C1", "unit": "EUR"}, {"understood": "\#(tail)"#
        #expect(understoods(partial) == ["a", "Et le "])
    }

    @Test func aFormulaFirstItemShowsItsUnderstoodOnceReached() {
        #expect(understoods(#"{"results": [{"formula": "C1", "unit": "EUR", "understood": "Le to"#) == ["Le to"])
        #expect(
            understoods(#"{"results": [{"formula": "C1"}, {"formula": "C2", "understood": "b"}]}"#) == ["b"])
    }

    @Test func anEscapedQuoteInAFormulaMakesNoPhantomResult() {
        let partial = #"{"results": [{"formula": "\"}, {\"understood\": \"x", "understood": "real"}]}"#
        #expect(understoods(partial) == ["real"])
    }

    @Test func aFourthItemIsNeverShown() {
        let item = { (text: String) in #"{"understood": "\#(text)", "formula": "C1", "unit": "none"}"# }
        let partial = #"{"results": [\#(item("a")), \#(item("b")), \#(item("c")), \#(item("d"))]}"#
        #expect(understoods(partial) == ["a", "b", "c"])
    }

    @Test func todaysFlatObjectGivesItsOne() {
        #expect(understoods(#"{"understood": "x", "formula": "C1"#) == ["x"])
        #expect(understoods(#"{"formula": "C1", "understood": "y"#) == ["y"])
    }

    @Test func anotherTopLevelKeyIsSkipped() {
        #expect(understoods(#"{"note": {"a": [1, "]"]}, "results": [{"understood": "z""#) == ["z"])
    }

    @Test func aFencedReplyReads() {
        #expect(understoods("```json\n" + #"{"results": [{"understood": "f"#) == ["f"])
    }

    @Test func everyCutIsAPrefixOfTheDecodedSet() throws {
        let decoded = try PlanSet.decode(setReply, finishReason: "stop").get().results.map(\.understood)
        #expect(understoods(setReply) == decoded)
        var previous: [String] = []
        for count in 0...setReply.count {
            let shown = understoods(String(setReply.prefix(count)))
            #expect(shown.count >= previous.count, "cut at \(count)")
            for (index, text) in shown.enumerated() {
                #expect(decoded[index].hasPrefix(text), "cut at \(count)")
                if index < previous.count { #expect(text.count >= previous[index].count) }
            }
            previous = shown
        }
    }
}
