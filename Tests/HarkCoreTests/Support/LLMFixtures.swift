import Foundation
import HarkCore
import Testing

/// Tests/HarkCoreTests/Fixtures/LLM: bodies recorded from MTPLX, and two written by hand (see its README).
enum LLMFixtures {
    static func data(_ name: String) throws -> Data {
        let directory = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try Data(contentsOf: directory.appending(path: "LLM").appending(path: name))
    }

    /// The events of a whole body fed in one piece.
    static func events(_ name: String) throws -> [ChatStreamItem] {
        var parser = SSEParser()
        let data = try data(name)
        return (parser.feed(data) + parser.finish()).map(ChatStreamItem.init(data:))
    }

    /// The answer `summary-fr.sse` streams.
    static let summaryText =
        "Lyon et Nantes ont achevé la migration du nouveau réseau, tandis que Bordeaux est en retard de deux semaines."
    static let model = "mtplx-bonsai-2-27b-optimized-speed"
}
