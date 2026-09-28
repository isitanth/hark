import Foundation
import HarkCore
import Testing

@Suite struct SSEParserTests {
    /// The recorded answer reads back whole, with the finish chunk's reason and usage.
    @Test func theRecordedSummary() throws {
        let items = try LLMFixtures.events("summary-fr.sse")
        let chunks = items.compactMap { item -> ChatStreamChunk? in
            if case .chunk(let chunk) = item { chunk } else { nil }
        }
        #expect(chunks.compactMap(\.content).joined() == LLMFixtures.summaryText)
        #expect(chunks.allSatisfy { $0.model == LLMFixtures.model })
        let finish = try #require(chunks.last)
        #expect(finish.finishReason == "stop" && finish.promptTokens == 94 && finish.completionTokens == 24)
        #expect(items.last == .done)
        #expect(!items.contains(.unreadable))
    }
}
