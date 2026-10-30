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

@Suite struct PlanStreamTests {
    @Test(arguments: [(openAIReply, openAIValue), (anthropicReply, anthropicValue), (labelledReply, labelledValue)])
    func everyCutGivesAPrefixOfTheFinalValue(_ reply: String, _ value: String) {
        var last = ""
        var started = false
        for count in 0...reply.count {
            let shown = PlanStream.understood(partial: String(reply.prefix(count)))
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
        #expect(PlanStream.understood(partial: reply) == value)
    }

    @Test func nilUntilTheOpeningQuote() {
        #expect(PlanStream.understood(partial: "") == nil)
        #expect(PlanStream.understood(partial: "{\"underst") == nil)
        #expect(PlanStream.understood(partial: "{\"understood\": ") == nil)
        #expect(PlanStream.understood(partial: "{\"understood\": \"") == "")
    }

    @Test func aFormulaFirstStillShowsItsUnderstoodLater() {
        let reply = #"{"formula": "SUM(C1, C2)", "unit": "EUR", "understood": "You want the total."}"#
        #expect(PlanStream.understood(partial: String(reply.prefix(30))) == nil)
        #expect(PlanStream.understood(partial: reply) == "You want the total.")
    }

    @Test func aFencedReplyAndABOM() {
        #expect(PlanStream.understood(partial: "```json\n{\"understood\": \"Total") == "Total")
        #expect(PlanStream.understood(partial: "\u{FEFF} {\"understood\": \"Total\"") == "Total")
    }

    @Test func aKeyInsideAStringNeverMatches() {
        let reply = #"{"formula": "the \"understood\": \"no\" trap", "understood": "yes"}"#
        #expect(PlanStream.understood(partial: reply) == "yes")
        #expect(PlanStream.understood(partial: String(reply.prefix(40))) == nil)
    }

    @Test func anEmptyValueAndNoUnderstoodAtAll() {
        #expect(PlanStream.understood(partial: #"{"understood": "", "formula": "C1""#) == "")
        #expect(PlanStream.understood(partial: #"{"formula": "C1", "unit": "EUR"}"#) == nil)
        #expect(PlanStream.understood(partial: "not json") == nil)
    }

    @Test func aLongValueStreamsWhole() {
        let value = String(repeating: "abcdé ", count: 100)
        #expect(value.count == 600)
        #expect(PlanStream.understood(partial: "{\"understood\": \"\(value)\", \"formula\": \"C1\"}") == value)
    }

    @Test func neverAnythingOfTheFormulaOrTheUnit() {
        for count in 0...anthropicReply.count {
            let shown = PlanStream.understood(partial: String(anthropicReply.prefix(count))) ?? ""
            #expect(!shown.contains("SUM") && !shown.contains("USD"))
        }
    }
}
