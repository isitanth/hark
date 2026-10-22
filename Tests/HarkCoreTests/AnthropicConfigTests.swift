import Foundation
import HarkCore
import Testing

/// commands.yaml with Claude's profile active, made of `fields` under `llm.profiles.claude`.
private func claudeFile(_ fields: [String]) -> String {
    LLMTexts.file(["provider: claude", "profiles:", "  claude:"] + fields.map { "    " + $0 })
}

private let claudeBase = "base_url: \"https://api.anthropic.com/v1\""
private let claudePath = "llm.profiles.claude"

struct EffortCase: Sendable, CustomTestStringConvertible {
    let effort: ReasoningEffort
    var testDescription: String { effort.rawValue }
}

let anthropicProblemCases: [LLMProblemCase] = [
    .init(
        "temperature is not for Claude", claudeFile([claudeBase, "api: anthropic", "temperature: 0.3"]),
        .unknownKey("temperature", path: claudePath, suggestion: nil)),
    .init(
        "extra is not for Claude", claudeFile([claudeBase, "api: anthropic", "extra: {top_k: 5}"]),
        .unknownKey("extra", path: claudePath, suggestion: nil)),
    .init(
        "effort is not for an OpenAI profile", LLMTexts.with("effort: low"),
        .unknownKey("effort", path: "llm.profiles.local", suggestion: nil)),
    .init(
        "an effort Claude does not know", claudeFile([claudeBase, "api: anthropic", "effort: huge"]),
        .invalidChoice(
            path: "\(claudePath).effort", value: "huge", allowed: ["low", "medium", "high", "xhigh", "max"])),
    .init(
        "a dialect Hark does not speak", claudeFile([claudeBase, "api: gemini"]),
        .invalidChoice(path: "\(claudePath).api", value: "gemini", allowed: ["openai", "anthropic"])),
    .init(
        "a key written in Claude's profile", claudeFile([claudeBase, "api: anthropic", "api_key: abc"]),
        .keyInFile(path: "\(claudePath).api_key")),
    .init(
        "the api key before api", claudeFile([claudeBase, "x_api_key: abc", "api: anthropic"]),
        .keyInFile(path: "\(claudePath).x_api_key")),
    .init(
        "a key after a misspelt api is still a key in the file",
        claudeFile([claudeBase, "api: anthropc", "api_key: abc"]),
        .keyInFile(path: "\(claudePath).api_key")),
    .init(
        "api twice is refused as a duplicate before the schema",
        claudeFile([claudeBase, "api: openai", "temperature: 0.3", "api: anthropic"]),
        .duplicateKey("api", path: "")),
]

@Suite struct AnthropicConfigTests {
    @Test func readsClaudesProfileWithItsDefaults() throws {
        let llm = try #require(try LLMTexts.llm(claudeFile([claudeBase, "api: anthropic"])))
        let profile = try #require(llm.activeProfile)
        #expect(profile.api == .anthropic)
        #expect(profile.key == .keychain)
        #expect(profile.model == .auto)
        #expect(profile.maxTokens == ProviderProfile.defaultAnthropicMaxTokens)
        #expect(profile.effort == nil)
        #expect(profile.extra.isEmpty)
        // The standard local profile is replaced by the file's profiles, as for any `profiles:`.
        #expect(llm.profiles.keys.sorted() == ["claude"])
    }

    @Test func readsEveryFieldOfClaudesProfile() throws {
        let text = claudeFile([
            claudeBase, "api: anthropic", "key: keychain", "model: \"claude-sonnet-5-5\"", "max_tokens: 4000",
            "effort: medium",
        ])
        let profile = try #require(try LLMTexts.llm(text)?.activeProfile)
        #expect(
            profile
                == ProviderProfile(
                    name: "claude", baseURL: URL(string: "https://api.anthropic.com/v1")!, api: .anthropic,
                    model: .named("claude-sonnet-5-5"), maxTokens: 4000, effort: .medium))
    }

    @Test(arguments: ReasoningEffort.allCases.map(EffortCase.init))
    func readsEveryEffort(_ row: EffortCase) throws {
        let text = claudeFile([claudeBase, "api: anthropic", "effort: \(row.effort.rawValue)"])
        #expect(try LLMTexts.llm(text)?.activeProfile?.effort == row.effort)
    }

    @Test func anOpenAIProfileSaysSoOrSaysNothing() throws {
        let written = try #require(try LLMTexts.llm(LLMTexts.with("api: openai"))?.activeProfile)
        let unsaid = try #require(try LLMTexts.llm(LLMTexts.with("key: keychain"))?.activeProfile)
        #expect(written == unsaid)
        #expect(written.api == .openAI)
        #expect(written.maxTokens == ProviderProfile.defaultMaxTokens)
    }

    @Test(arguments: anthropicProblemCases)
    func refuses(_ testCase: LLMProblemCase) {
        #expect(LLMTexts.error(testCase.text)?.problem == testCase.problem)
    }

    @Test func claudesProfileRoundTripsWithOnlyItsOwnKeys() throws {
        var bare = ProviderProfile.claude
        bare.effort = nil
        bare.name = "bare"
        let config = CommandConfig(
            llm: LLMConfig(provider: "claude", profiles: ["local": .local, "claude": .claude, "bare": bare]))
        let yaml = config.yaml()
        #expect(try CommandConfig.parse(Data(yaml.utf8)) == config)
        let claudeLines = yaml.components(separatedBy: "\n").drop { $0 != "    \"claude\":" }.prefix(7)
        #expect(
            Array(claudeLines) == [
                "    \"claude\":", "      base_url: \"https://api.anthropic.com/v1\"", "      api: anthropic",
                "      key: keychain", "      model: \"claude-opus-5-5\"", "      max_tokens: 16000",
                "      effort: low",
            ])
        // The local profile is written as before 2026-10-12, without `api:`.
        #expect(!yaml.contains("api: openai"))
    }

    @Test func pickingClaudeAddsItsProfileAndLeavesTheLocalOneAlone() throws {
        let local = with(.standard, base: "http://127.0.0.1:8002/v1")
        let next = try #require(CommandConfig(llm: local).settingProvider("claude"))
        #expect(next.llm?.provider == "claude")
        #expect(next.llm?.profiles["claude"] == .claude)
        #expect(next.llm?.profiles["local"] == local.profiles["local"])
        #expect(try CommandConfig.parse(Data(next.yaml().utf8)) == next)
    }

    @Test func pickingClaudeInAFileWithNoLLMWritesTheStandardOneToo() throws {
        let next = try #require(CommandConfig().settingProvider("claude"))
        #expect(next.llm?.profiles.keys.sorted() == ["claude", "local"])
        #expect(next.llm?.activeProfile == .claude)
    }

    @Test func pickingAProfileTheFileHasKeepsItAsWritten() throws {
        var mine = ProviderProfile.claude
        mine.model = .named("claude-haiku-5-5")
        mine.effort = nil
        let config = CommandConfig(llm: LLMConfig(provider: "local", profiles: ["local": .local, "claude": mine]))
        let next = try #require(config.settingProvider("claude"))
        #expect(next.llm?.activeProfile == mine)
        let back = try #require(next.settingProvider("local"))
        #expect(back.llm?.provider == "local")
        #expect(back.llm?.profiles["claude"] == mine)
    }

    @Test func pickingLocalWhereTheFileHasOnlyClaudeAddsTheLocalTemplate() throws {
        let config = CommandConfig(llm: LLMConfig(provider: "claude", profiles: ["claude": .claude]))
        let next = try #require(config.settingProvider("local"))
        #expect(next.llm?.activeProfile == .local)
        #expect(next.llm?.profiles["claude"] == .claude)
    }

    @Test func anUnknownNameIsNotPicked() {
        #expect(CommandConfig().settingProvider("work") == nil)
    }

    @Test func theAddressGoesToClaudesProfileOnceItIsPicked() throws {
        let config = try #require(CommandConfig().settingProvider("claude"))
        let next = try #require(config.settingServerAddress("https://proxy.example.com/anthropic/v1"))
        #expect(next.llm?.profiles["claude"]?.baseURL.absoluteString == "https://proxy.example.com/anthropic/v1")
        #expect(next.llm?.profiles["claude"]?.api == .anthropic)
        #expect(next.llm?.profiles["local"] == .local)
    }

    private func with(_ llm: LLMConfig, base: String) -> LLMConfig {
        var llm = llm
        llm.profiles[llm.provider]?.baseURL = URL(string: base)!
        return llm
    }
}
