import Foundation
import HarkCore
import Testing

struct RetiredDefaultCase: Sendable, CustomTestStringConvertible {
    let fixture: String
    let sha256: String

    var testDescription: String { fixture }
}

let retiredVersion2Defaults: [RetiredDefaultCase] = [
    .init(
        fixture: "commands-v2-m6.9-default.yaml",
        sha256: "ba8bf43de18320ed163fc9f5ae76ff2257a67b2e6d0c48edf36d32d1458038d9"),
    .init(
        fixture: "commands-v2-m7-default.yaml",
        sha256: "2a36af4860fb64b0644ac93a316a923e971011c54bc3925e5d919a8b64e0a732"),
]

/// What version 3 changes for the store: the two version 2 defaults retire, and a bad `llm:` is a bad file.
@Suite("Config store: llm")
struct ConfigStoreLLMTests {
    @Test(arguments: retiredVersion2Defaults)
    func anUneditedVersion2DefaultIsReplacedAtStart(_ retired: RetiredDefaultCase) async throws {
        let bytes = try ConfigFixtures.data(retired.fixture)
        #expect(ConfigRevision(of: bytes).sha256 == retired.sha256)
        let harness = try StoreHarness()
        try harness.put(String(decoding: bytes, as: UTF8.self))
        await harness.store.start()
        let first = try await harness.next()
        #expect(first.source == .file && first.error == nil)
        #expect(harness.bytes() == harness.bytes(harness.defaults))
    }

    @Test func anEditedVersion2DefaultStaysAndStillReads() async throws {
        let text = String(decoding: try ConfigFixtures.data("commands-v2-m7-default.yaml"), as: UTF8.self) + "# mine\n"
        let harness = try StoreHarness()
        try harness.put(text)
        await harness.store.start()
        let first = try await harness.next()
        #expect(first.source == .file && first.error == nil)
        #expect(first.config.llm == nil)
        #expect(harness.bytes() == Data(text.utf8))
    }

    @Test func aBadLLMBlockKeepsTheLastGoodConfig() async throws {
        let harness = try StoreHarness()
        let good = LLMTexts.url("https://example.com/v1")
        try harness.put(good)
        await harness.store.start()
        let first = try await harness.next()
        #expect(first.config.llm?.activeProfile?.baseURL == URL(string: "https://example.com/v1"))

        let bad = LLMTexts.with("key: \"sk-live-abc\"")
        try harness.put(bad)
        await harness.change()
        harness.clock.advance(by: .milliseconds(100))
        let degraded = try await harness.next()
        #expect(degraded.source == .lastGood)
        #expect(degraded.config == first.config)
        #expect(degraded.error?.problem == .keyInFile(path: "llm.profiles.local.key"))
        #expect(degraded.error?.description.contains("sk-live-abc") == false)
        #expect(harness.bytes(harness.lastGood) == Data(good.utf8))
    }

    @Test func aFileForALaterMilestoneIsRefused() async throws {
        let harness = try StoreHarness()
        try harness.put(ConfigTexts.valid("one"))
        await harness.store.start()
        let first = try await harness.next()

        try harness.put(LLMTexts.file(["routing: {}"]))
        await harness.change()
        harness.clock.advance(by: .milliseconds(100))
        let degraded = try await harness.next()
        #expect(degraded.source == .lastGood && degraded.config == first.config)
        #expect(degraded.error?.problem == .unknownKey("routing", path: "llm", suggestion: nil))
    }

    @Test func writingTheCommandsBackKeepsTheLLMBlock() async throws {
        let harness = try StoreHarness()
        try harness.put(LLMTexts.url("https://example.com/v1"))
        await harness.store.start()
        let first = try await harness.next()
        var next = first.config
        next.commands = [CommandEntry(id: "open_finder", app: "Finder")]
        try await harness.store.write(next.yaml(), basedOn: first.diskRevision)
        let written = try await harness.next()
        #expect(written.config.llm == first.config.llm)
        #expect(written.config.commands == next.commands)
    }
}
