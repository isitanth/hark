import Foundation
import HarkCore
import Testing

struct SSEFeedCase: Sendable, CustomTestStringConvertible {
    let fixture: String
    let piece: Int
    var testDescription: String { "\(fixture) in pieces of \(piece)" }
}

struct SSEBytesCase: Sendable, CustomTestStringConvertible {
    let name: String
    let body: String
    let events: [String]
    var testDescription: String { name }
}

struct StreamItemCase: Sendable, CustomTestStringConvertible {
    let name: String
    let data: String
    let item: ChatStreamItem
    var testDescription: String { name }
}

struct ErrorBodyCase: Sendable, CustomTestStringConvertible {
    let name: String
    let body: Data
    let message: String?
    var testDescription: String { name }
}

@Suite struct SSEParserTests {
    static let bigFixtures = ["summary-fr.sse", "thinking-on.sse", "long-prefill.sse", "error-in-stream.sse"]
    static let feeds: [SSEFeedCase] = bigFixtures.flatMap { name in
        [1, 7, 64, 4096].map { SSEFeedCase(fixture: name, piece: $0) }
    }

    /// Every body is fed whole, then its events read back one per blank line.
    static let bodies: [SSEBytesCase] = [
        .init(name: "LF", body: "data: a\n\ndata: b\n\n", events: ["a", "b"]),
        .init(name: "CRLF", body: "data: a\r\n\r\ndata: b\r\n\r\n", events: ["a", "b"]),
        .init(name: "CR", body: "data: a\r\rdata: b\r\r", events: ["a", "b"]),
        .init(name: "mixed endings", body: "data: a\r\n\ndata: b\r\rdata: c\n\r\n", events: ["a", "b", "c"]),
        .init(name: "data: without the space", body: "data:a\n\n", events: ["a"]),
        .init(name: "only the first space is dropped", body: "data:  a \n\n", events: [" a "]),
        .init(name: "two data lines in one event", body: "data: a\ndata: b\n\n", events: ["a\nb"]),
        .init(name: "an empty data line counts", body: "data:\ndata: b\n\n", events: ["\nb"]),
        .init(name: "a blank line with no data", body: "\n\n\r\n\r\r", events: []),
        .init(
            name: "event, id, retry and unknown fields",
            body: "event: message\nid: 7\nretry: 3000\nfoo: bar\ndatum: x\n: note\ndata: a\n\n", events: ["a"]),
        .init(name: "a comment alone", body: ": keep-alive\n\n", events: []),
        .init(name: "a last line with no newline", body: "data: a\n\ndata: [DONE]", events: ["a", "[DONE]"]),
        .init(name: "a last event with no blank line", body: "data: a\n", events: ["a"]),
        .init(name: "nothing", body: "", events: []),
    ]

    static let items: [StreamItemCase] = [
        .init(name: "[DONE]", data: "[DONE]", item: .done),
        .init(name: "[DONE] with spaces", data: " [DONE] ", item: .done),
        .init(name: "not JSON", data: "hello", item: .unreadable),
        .init(name: "a JSON array", data: "[1, 2]", item: .unreadable),
        .init(name: "empty", data: "", item: .unreadable),
        .init(
            name: "OpenAI's last chunk, no choices and a usage",
            data: #"{"model": "gpt", "choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 9}}"#,
            item: .chunk(ChatStreamChunk(model: "gpt", promptTokens: 5, completionTokens: 9))),
        .init(
            name: "empty content reads as nil",
            data: #"{"model": "m", "choices": [{"delta": {"content": ""}, "finish_reason": null}]}"#,
            item: .chunk(ChatStreamChunk(model: "m"))),
        .init(
            name: "content",
            data: #"{"choices": [{"delta": {"content": " et"}}]}"#, item: .chunk(ChatStreamChunk(content: " et"))),
        .init(
            name: "reasoning only",
            data: #"{"choices": [{"delta": {"reasoning_content": "We "}}]}"#, item: .chunk(ChatStreamChunk())),
        .init(name: "error as text", data: #"{"error": "boom"}"#, item: .error(message: "boom")),
        .init(
            name: "error with a message", data: #"{"error": {"message": "boom", "type": "server_error"}}"#,
            item: .error(message: "boom")),
        .init(name: "error with nothing", data: #"{"error": {}}"#, item: .error(message: nil)),
    ]

    static func errorBodies() throws -> [ErrorBodyCase] {
        [
            .init(
                name: "401", body: try LLMFixtures.data("unauthorized-401.json"),
                message: "missing or invalid API key"),
            .init(
                name: "500", body: try LLMFixtures.data("server-error-500.json"),
                message: "Model is still loading, try again in a minute"),
            .init(name: "not JSON", body: Data("<html>Bad Gateway</html>".utf8), message: nil),
            .init(name: "{}", body: Data("{}".utf8), message: nil),
            .init(name: "an empty body", body: Data(), message: nil),
        ]
    }

    /// The events of `bytes` fed in pieces cut at `cuts`, then finished.
    static func events(_ bytes: [UInt8], cuts: [Int]) -> [String] {
        var parser = SSEParser()
        var events: [String] = []
        var start = 0
        for cut in cuts + [bytes.count] {
            events += parser.feed(bytes[start..<cut])
            start = cut
        }
        return events + parser.finish()
    }

    static func events(_ bytes: [UInt8], piece: Int) -> [String] {
        events(bytes, cuts: Array(stride(from: piece, to: bytes.count, by: piece)))
    }

    static func chunks(_ items: [ChatStreamItem]) -> [ChatStreamChunk] {
        items.compactMap { item -> ChatStreamChunk? in
            if case .chunk(let chunk) = item { chunk } else { nil }
        }
    }

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

    /// The role chunk and the empty `mtplx_progress` deltas carry no content; every data line is one item.
    @Test func theSummaryChunkByChunk() throws {
        let items = try LLMFixtures.events("summary-fr.sse")
        #expect(items.count == 29)
        let chunks = Self.chunks(items)
        #expect(chunks.first == ChatStreamChunk(model: LLMFixtures.model))
        let empty = chunks.dropLast().filter { $0.content == nil }
        #expect(empty.count > 1)
        #expect(empty.allSatisfy { $0.finishReason == nil && $0.promptTokens == nil })
        #expect(chunks.dropLast().allSatisfy { $0.finishReason == nil })
        #expect(chunks.filter { $0.finishReason != nil }.count == 1)
        #expect(items.filter { $0 == .done }.count == 1)
    }

    /// Thinking on: `reasoning_content` alone, so not a word of content, and the budget ran out.
    @Test func thinkingOnHasNoContent() throws {
        let items = try LLMFixtures.events("thinking-on.sse")
        let chunks = Self.chunks(items)
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { $0.content == nil })
        let finish = try #require(chunks.last)
        #expect(finish.finishReason == "length" && finish.promptTokens == 132 && finish.completionTokens == 48)
        #expect(items.last == .done)
        #expect(!items.contains(.unreadable))
    }

    /// The `: keep-alive` comment sent during the prefill yields no item, and the answer still reads whole.
    @Test func theKeepAliveYieldsNothing() throws {
        let body = try LLMFixtures.data("long-prefill.sse")
        #expect(String(decoding: body, as: UTF8.self).contains("\n: keep-alive\n"))
        let items = try LLMFixtures.events("long-prefill.sse")
        #expect(items.count == 29)
        #expect(!items.contains(.unreadable))
        let chunks = Self.chunks(items)
        #expect(
            chunks.compactMap(\.content).joined()
                == "Lyon et Nantes ont terminé la migration du nouveau réseau, tandis que Bordeaux accuse un retard de "
                + "deux semaines.")
        #expect(chunks.last?.finishReason == "stop" && chunks.last?.promptTokens == 2396)
        #expect(items.last == .done)
    }

    @Test func theErrorInTheStream() throws {
        let items = try LLMFixtures.events("error-in-stream.sse")
        #expect(items.last == .error(message: "The model crashed while generating"))
        #expect(!items.contains(.done))
        #expect(Self.chunks(items).compactMap(\.content).joined() == "Lyon et")
    }

    @Test(arguments: feeds) func piecesGiveTheSameEvents(_ c: SSEFeedCase) throws {
        let bytes = [UInt8](try LLMFixtures.data(c.fixture))
        let whole = Self.events(bytes, cuts: [])
        #expect(!whole.isEmpty)
        #expect(Self.events(bytes, piece: c.piece) == whole)
    }

    @Test func aCutAtEveryByteGivesTheSameEvents() throws {
        let bytes = [UInt8](try LLMFixtures.data("error-in-stream.sse"))
        let whole = Self.events(bytes, cuts: [])
        let differing = (0...bytes.count).filter { Self.events(bytes, cuts: [$0]) != whole }
        #expect(differing.isEmpty)
    }

    @Test func aMultibyteCharacterSplitBetweenTwoPieces() {
        let bytes = [UInt8]("data: \u{E9}\n\n".utf8)
        #expect(bytes[6...7] == [0xC3, 0xA9])
        #expect(Self.events(bytes, cuts: [7]) == ["\u{E9}"])
    }

    @Test func aCRLFSplitBetweenTwoPieces() {
        let bytes = [UInt8]("data: a\r\n\r\ndata: b\r\n\r\n".utf8)
        for cut in 1..<bytes.count {
            #expect(Self.events(bytes, cuts: [cut]) == ["a", "b"], "cut at \(cut)")
        }
    }

    /// A CRLF split after its CR must not end a second, blank line when its LF arrives.
    @Test func aCRLFSplitDispatchesOnlyOnce() {
        var parser = SSEParser()
        #expect(parser.feed(Array("data: a\r".utf8)).isEmpty)
        #expect(parser.feed(Array("\ndata: b\r\n\r\n".utf8)) == ["a\nb"])
    }

    @Test(arguments: bodies) func theWire(_ c: SSEBytesCase) {
        #expect(Self.events(Array(c.body.utf8), cuts: []) == c.events)
    }

    @Test func finishOnAnEmptyParserIsEmpty() {
        var parser = SSEParser()
        #expect(parser.finish().isEmpty)
        #expect(parser.finish().isEmpty)
    }

    @Test func finishDispatchesALastLineWithNoNewline() {
        var parser = SSEParser()
        #expect(parser.feed(Array("data: a".utf8)).isEmpty)
        #expect(parser.finish() == ["a"])
        #expect(parser.finish().isEmpty)
    }

    @Test(arguments: items) func theItem(_ c: StreamItemCase) {
        #expect(ChatStreamItem(data: c.data) == c.item)
    }

    @Test func theErrorBodies() throws {
        for c in try Self.errorBodies() {
            #expect(LLMErrorBody.message(in: c.body) == c.message, "\(c.name)")
        }
    }
}
