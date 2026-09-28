import Foundation
import HarkCore
import Testing

/// commands.yaml texts with an `llm:` block, for the version 3 tests.
enum LLMTexts {
    /// A version 3 file whose `llm:` is `lines`, each indented under it.
    static func file(_ lines: [String], version: Int = 3) -> String {
        (["version: \(version)", "commands: []", "llm:"] + lines.map { "  " + $0 }).joined(separator: "\n") + "\n"
    }

    /// One profile named `local` made of `fields`, each indented under it.
    static func profile(_ fields: [String]) -> String {
        file(["profiles:", "  local:"] + fields.map { "    " + $0 })
    }

    /// The local profile with `field` added to its base_url.
    static func with(_ field: String) -> String {
        profile(["base_url: \"https://example.com/v1\"", field])
    }

    static func url(_ url: String) -> String {
        profile(["base_url: \"\(url)\""])
    }

    static func llm(_ text: String) throws -> LLMConfig? {
        try ConfigFixtures.parse(text).llm
    }

    static func error(_ text: String) -> ConfigError? {
        do throws(ConfigError) {
            _ = try CommandConfig.parse(Data(text.utf8))
            return nil
        } catch {
            return error
        }
    }
}

struct LLMAcceptCase: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    let llm: LLMConfig?

    init(_ name: String, _ text: String, _ llm: LLMConfig?) {
        self.name = name
        self.text = text
        self.llm = llm
    }

    var testDescription: String { name }
}

struct LLMProblemCase: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    let problem: ConfigProblem

    init(_ name: String, _ text: String, _ problem: ConfigProblem) {
        self.name = name
        self.text = text
        self.problem = problem
    }

    var testDescription: String { name }
}

private let example = URL(string: "https://example.com/v1")!

private func local(_ url: String, key: KeySource = .keychain) -> LLMConfig {
    LLMConfig(
        provider: "local", profiles: ["local": ProviderProfile(name: "local", baseURL: URL(string: url)!, key: key)])
}

let llmAcceptCases: [LLMAcceptCase] = [
    .init("version 3 without llm", "version: 3\ncommands: []\n", nil),
    .init("version 2 reads as 3 without llm", "version: 2\ncommands: []\n", nil),
    .init("an empty llm is the standard one", LLMTexts.file(["provider: local"]), .standard),
    .init("a null llm is no llm", "version: 3\nllm:\n", nil),
    .init("every default filled in", LLMTexts.url("https://example.com/v1"), local("https://example.com/v1")),
    .init(
        "every field written out",
        LLMTexts.file([
            "provider: work", "max_selection_chars: 500", "profiles:", "  work:",
            "    base_url: \"https://api.example.com/v1\"", "    key: none", "    model: \"gpt-x\"",
            "    temperature: 2", "    max_tokens: 131072",
            "    extra: {enable_thinking: true, top_k: 40, top_p: 0.9, tone: \"dry\", seed: \"7\"}",
        ]),
        LLMConfig(
            provider: "work",
            profiles: [
                "work": ProviderProfile(
                    name: "work", baseURL: URL(string: "https://api.example.com/v1")!, key: .none,
                    model: .named("gpt-x"), temperature: 2, maxTokens: 131_072,
                    extra: [
                        "enable_thinking": .bool(true), "top_k": .int(40), "top_p": .double(0.9),
                        "tone": .string("dry"), "seed": .string("7"),
                    ])
            ], maxSelectionChars: 500)),
    .init(
        "the lower bounds", LLMTexts.file(["max_selection_chars: 1"]) + "",
        LLMConfig(provider: "local", profiles: LLMConfig.standard.profiles, maxSelectionChars: 1)),
    .init(
        "temperature 0 and max_tokens 1",
        LLMTexts.profile(["base_url: \"https://example.com/v1\"", "temperature: 0", "max_tokens: 1"]),
        LLMConfig(
            provider: "local",
            profiles: ["local": ProviderProfile(name: "local", baseURL: example, temperature: 0, maxTokens: 1)])),
    .init("http to 127.0.0.1", LLMTexts.url("http://127.0.0.1:8002/v1"), local("http://127.0.0.1:8002/v1")),
    .init("http to 127.9.9.9", LLMTexts.url("http://127.9.9.9/v1"), local("http://127.9.9.9/v1")),
    .init("http to localhost", LLMTexts.url("http://localhost:8000/v1"), local("http://localhost:8000/v1")),
    .init("http to [::1]", LLMTexts.url("http://[::1]:8000/v1"), local("http://[::1]:8000/v1")),
    .init("https to any host", LLMTexts.url("https://10.0.0.2:8443/v1"), local("https://10.0.0.2:8443/v1")),
    .init("a null extra is empty", LLMTexts.with("extra:"), local("https://example.com/v1")),
    .init("a null extra field is absent", LLMTexts.with("extra: {top_k: ~}"), local("https://example.com/v1")),
]

private let profilePath = "llm.profiles.local"

let llmProblemCases: [LLMProblemCase] = [
    .init("llm in a version 2 file", LLMTexts.file([], version: 2), .unknownKey("llm", path: "", suggestion: nil)),
    .init("version 4", "version: 4\ncommands: []\n", .unsupportedVersion("4")),
    .init("llm as a list", "version: 3\nllm: [a]\n", .wrongType(path: "llm", expected: .mapping)),
    .init(
        "unknown key in llm", LLMTexts.file(["providr: local"]),
        .unknownKey("providr", path: "llm", suggestion: "provider")),
    .init(
        "unknown key in a profile", LLMTexts.with("temprature: 1"),
        .unknownKey("temprature", path: profilePath, suggestion: "temperature")),
    .init("a profile without base_url", LLMTexts.profile(["key: none"]), .missingKey("base_url", path: profilePath)),
    .init(
        "a null profile", LLMTexts.file(["profiles:", "  local:"]), .wrongType(path: profilePath, expected: .mapping)),
    .init("profiles as a list", LLMTexts.file(["profiles: [a]"]), .wrongType(path: "llm.profiles", expected: .mapping)),
    .init("provider naming no profile", LLMTexts.file(["provider: work"]), .unknownProfile("work")),
    .init("no profile at all", LLMTexts.file(["profiles: {}"]), .unknownProfile("local")),
    .init(
        "an uppercase profile name", LLMTexts.file(["profiles:", "  Work: {}"]),
        .outOfRange(path: "llm.profiles", value: "Work")),
    .init(
        "a profile name with a dot", LLMTexts.file(["profiles:", "  a.b: {}"]),
        .outOfRange(path: "llm.profiles", value: "a.b")),
    .init(
        "a profile name starting with -", LLMTexts.file(["profiles:", "  \"-a\": {}"]),
        .outOfRange(path: "llm.profiles", value: "-a")),
    .init(
        "a 33-character profile name", LLMTexts.file(["profiles:", "  \(String(repeating: "a", count: 33)): {}"]),
        .outOfRange(path: "llm.profiles", value: String(repeating: "a", count: 33))),
    .init(
        "max_selection_chars 0", LLMTexts.file(["max_selection_chars: 0"]),
        .outOfRange(path: "llm.max_selection_chars", value: "0")),
    .init(
        "max_selection_chars 100001", LLMTexts.file(["max_selection_chars: 100001"]),
        .outOfRange(path: "llm.max_selection_chars", value: "100001")),
    .init(
        "max_selection_chars 1.5", LLMTexts.file(["max_selection_chars: 1.5"]),
        .outOfRange(path: "llm.max_selection_chars", value: "1.5")),
    .init(
        "max_selection_chars as text", LLMTexts.file(["max_selection_chars: \"12\""]),
        .outOfRange(path: "llm.max_selection_chars", value: "12")),
    .init("provider as a list", LLMTexts.file(["provider: [a]"]), .wrongType(path: "llm.provider", expected: .text)),
    .init(
        "temperature -0.1", LLMTexts.with("temperature: -0.1"),
        .outOfRange(path: "\(profilePath).temperature", value: "-0.1")),
    .init(
        "temperature 2.01", LLMTexts.with("temperature: 2.01"),
        .outOfRange(path: "\(profilePath).temperature", value: "2.01")),
    .init(
        "temperature as a word", LLMTexts.with("temperature: warm"),
        .outOfRange(path: "\(profilePath).temperature", value: "warm")),
    .init(
        "temperature as a list", LLMTexts.with("temperature: [1]"),
        .wrongType(path: "\(profilePath).temperature", expected: .number)),
    .init("max_tokens 0", LLMTexts.with("max_tokens: 0"), .outOfRange(path: "\(profilePath).max_tokens", value: "0")),
    .init(
        "max_tokens 131073", LLMTexts.with("max_tokens: 131073"),
        .outOfRange(path: "\(profilePath).max_tokens", value: "131073")),
    .init(
        "max_tokens 10.5", LLMTexts.with("max_tokens: 10.5"),
        .outOfRange(path: "\(profilePath).max_tokens", value: "10.5")),
    .init(
        "max_tokens 1e3", LLMTexts.with("max_tokens: 1e3"), .outOfRange(path: "\(profilePath).max_tokens", value: "1e3")
    ),
    .init("model as a list", LLMTexts.with("model: [a]"), .wrongType(path: "\(profilePath).model", expected: .text)),
    .init("a blank model", LLMTexts.with("model: \" \""), .emptyText(path: "\(profilePath).model")),
    .init(
        "base_url as a list", LLMTexts.profile(["base_url: [a]"]),
        .wrongType(path: "\(profilePath).base_url", expected: .text)),
    .init(
        "plain http to another host", LLMTexts.url("http://example.com/v1"),
        .insecureURL(path: "\(profilePath).base_url", value: "http://example.com/v1")),
    .init(
        "plain http to the LAN", LLMTexts.url("http://192.168.1.2:8000/v1"),
        .insecureURL(path: "\(profilePath).base_url", value: "http://192.168.1.2:8000/v1")),
    .init(
        "plain http to 128.0.0.1", LLMTexts.url("http://128.0.0.1/v1"),
        .insecureURL(path: "\(profilePath).base_url", value: "http://128.0.0.1/v1")),
    .init(
        "a query", LLMTexts.url("https://example.com/v1?x=1"),
        .invalidURL(path: "\(profilePath).base_url", value: "https://example.com/v1")),
    .init(
        "a fragment", LLMTexts.url("https://example.com/v1#x"),
        .invalidURL(path: "\(profilePath).base_url", value: "https://example.com/v1")),
    .init("relative", LLMTexts.url("v1/chat"), .invalidURL(path: "\(profilePath).base_url", value: "v1/chat")),
    .init(
        "ftp", LLMTexts.url("ftp://example.com/v1"),
        .invalidURL(path: "\(profilePath).base_url", value: "ftp://example.com/v1")),
    .init("no host", LLMTexts.url("https:///v1"), .invalidURL(path: "\(profilePath).base_url", value: "https:///v1")),
    .init(
        "not a URL", LLMTexts.url("https://exa mple.com"),
        .invalidURL(path: "\(profilePath).base_url", value: "https://exa mple.com")),
    .init(
        "user and password", LLMTexts.url("https://me:hunter2@example.com/v1"),
        .keyInFile(path: "\(profilePath).base_url")),
    .init("user alone", LLMTexts.url("https://me@example.com/v1"), .keyInFile(path: "\(profilePath).base_url")),
    .init("key: sk-live-abc", LLMTexts.with("key: \"sk-live-abc\""), .keyInFile(path: "\(profilePath).key")),
    .init("key: abc", LLMTexts.with("key: abc"), .keyInFile(path: "\(profilePath).key")),
    .init("key: 123", LLMTexts.with("key: 123"), .keyInFile(path: "\(profilePath).key")),
    .init("key: Keychain", LLMTexts.with("key: Keychain"), .keyInFile(path: "\(profilePath).key")),
    .init("key as a mapping", LLMTexts.with("key: {value: abc}"), .keyInFile(path: "\(profilePath).key")),
    .init("api_key in a profile", LLMTexts.with("api_key: abc"), .keyInFile(path: "\(profilePath).api_key")),
    .init("extra as a list", LLMTexts.with("extra: [a]"), .wrongType(path: "\(profilePath).extra", expected: .mapping)),
    .init(
        "extra with a nested mapping", LLMTexts.with("extra: {a: {b: 1}}"),
        .wrongType(path: "\(profilePath).extra.a", expected: .text)),
    .init(
        "extra with a list", LLMTexts.with("extra: {a: [1]}"),
        .wrongType(path: "\(profilePath).extra.a", expected: .text)),
    .init(
        "extra setting model", LLMTexts.with("extra: {model: x}"),
        .outOfRange(path: "\(profilePath).extra", value: "model")),
    .init(
        "extra setting stream", LLMTexts.with("extra: {stream: false}"),
        .outOfRange(path: "\(profilePath).extra", value: "stream")),
    .init(
        "extra setting response_format", LLMTexts.with("extra: {response_format: x}"),
        .outOfRange(path: "\(profilePath).extra", value: "response_format")),
    .init(
        "an extra name with a capital", LLMTexts.with("extra: {Top_k: 1}"),
        .outOfRange(path: "\(profilePath).extra", value: "Top_k")),
    .init(
        "an extra name with a dash", LLMTexts.with("extra: {top-k: 1}"),
        .outOfRange(path: "\(profilePath).extra", value: "top-k")),
    .init(
        "a duplicate extra name", LLMTexts.with("extra: {a: 1, a: 2}"),
        .duplicateKey("a", path: "")),
    .init("extra api_key", LLMTexts.with("extra: {api_key: abc}"), .keyInFile(path: "\(profilePath).extra.api_key")),
    .init(
        "extra Access_Token", LLMTexts.with("extra: {Access_Token: abc}"),
        .keyInFile(path: "\(profilePath).extra.Access_Token")),
    .init(
        "extra secret", LLMTexts.with("extra: {client_secret: abc}"),
        .keyInFile(path: "\(profilePath).extra.client_secret")),
    .init(
        "extra auth", LLMTexts.with("extra: {authorization: abc}"),
        .keyInFile(path: "\(profilePath).extra.authorization")),
    .init("extra PASSWORD", LLMTexts.with("extra: {PASSWORD: abc}"), .keyInFile(path: "\(profilePath).extra.PASSWORD")),
]

struct LLMRoundTripCase: Sendable, CustomTestStringConvertible {
    let name: String
    let config: CommandConfig

    var testDescription: String { name }
}

private let everyKind = ProviderProfile(
    name: "work-2", baseURL: URL(string: "https://api.example.com:8443/openai/v1")!, key: .none,
    model: .named("model \"quoted\" été 東京 🎉"), temperature: 1.25, maxTokens: 4096,
    extra: [
        "flag": .bool(true), "off": .bool(false), "count": .int(-3), "whole": .double(1), "tiny": .double(1e-05),
        "ratio": .double(0.5), "text": .string("say \"hi\"\n\té"), "looks_true": .string("true"),
        "looks_int": .string("42"), "empty": .string(""),
    ])

let llmRoundTripCases: [LLMRoundTripCase] = [
    .init(name: "no llm", config: CommandConfig(commands: [CommandEntry(id: "open_finder", app: "Finder")])),
    .init(name: "the standard llm", config: CommandConfig(llm: .standard)),
    .init(name: "the bundled default", config: ConfigFixtures.commands),
    .init(
        name: "several profiles, every value kind",
        config: CommandConfig(
            commands: [CommandEntry(id: "open_notes", app: "Notes", aliases: ["note"])],
            llm: LLMConfig(
                provider: "work-2",
                profiles: [
                    "local": .local, "work-2": everyKind,
                    "a_loop": ProviderProfile(
                        name: "a_loop", baseURL: URL(string: "http://[::1]:9000/v1")!, temperature: 0, maxTokens: 1),
                ], maxSelectionChars: 100_000))),
]

@Suite struct CommandConfigLLMTests {
    @Test(arguments: llmAcceptCases)
    func reads(_ testCase: LLMAcceptCase) throws {
        #expect(try LLMTexts.llm(testCase.text) == testCase.llm)
    }

    @Test(arguments: llmProblemCases)
    func refuses(_ testCase: LLMProblemCase) {
        #expect(LLMTexts.error(testCase.text)?.problem == testCase.problem)
    }

    @Test func versionTwoReadsAsThree() throws {
        let config = try CommandConfig.parse(try ConfigFixtures.data("commands-v2-m7-default.yaml"))
        #expect(config.llm == nil)
        #expect(config.effectiveLLM == .standard)
        var expected = ConfigFixtures.commands
        expected.llm = nil
        #expect(config == expected)
        #expect(config.yaml().hasPrefix("version: 3\n"))
    }

    @Test func theBundledDefaultIsTheStandardProfile() throws {
        let url = try #require(BundledResources.defaultCommands)
        let config = try CommandConfig.parse(try Data(contentsOf: url))
        #expect(config.llm == LLMConfig.standard)
        #expect(config.effectiveLLM.activeProfile == ProviderProfile.local)
    }

    /// A key that reached the file is never repeated: not in the log's description, not in the UI's text.
    @Test(arguments: [
        "key: \"sk-live-abc\"", "key: abc123secret", "api_key: \"sk-live-abc\"", "extra: {token: \"sk-live-abc\"}",
    ])
    func aKeyInTheFileIsNeverEchoed(_ field: String) throws {
        let error = try #require(LLMTexts.error(LLMTexts.with(field)))
        guard case .keyInFile = error.problem else {
            Issue.record("\(error.problem)")
            return
        }
        for secret in ["sk-live-abc", "abc123secret"] {
            #expect(!error.description.contains(secret))
            #expect(!"\(error.problem)".contains(secret))
        }
    }

    @Test func aPasswordInTheURLIsNeverEchoed() throws {
        let error = try #require(LLMTexts.error(LLMTexts.url("https://me:hunter2@example.com/v1")))
        #expect(!error.description.contains("hunter2"))
        #expect(!"\(error.problem)".contains("hunter2"))
    }

    @Test func aRefusedURLIsQuotedWithoutItsQuery() throws {
        let error = try #require(LLMTexts.error(LLMTexts.url("https://example.com/v1?api=sk-live-abc")))
        #expect(!error.description.contains("sk-live-abc"))
    }

    @Test(arguments: llmRoundTripCases)
    func parsingTheEmittedTextGivesTheValueBack(_ testCase: LLMRoundTripCase) throws {
        let text = testCase.config.yaml()
        #expect(try ConfigFixtures.parse(text) == testCase.config, "\(text)")
        #expect(try ConfigFixtures.parse(text).yaml() == text)
    }

    @Test func emitsTheCanonicalBlock() {
        let expected = """
            version: 3

            defaults:
              threshold: 0.85

            commands: []

            llm:
              provider: "local"
              profiles:
                "local":
                  base_url: "http://127.0.0.1:8000/v1"
                  key: keychain
                  model: auto
                  temperature: 0.3
                  max_tokens: 1024
                  extra: {"enable_thinking": false}
              max_selection_chars: 12000

            """
        #expect(CommandConfig(llm: .standard).yaml() == expected)
    }

    @Test func editingTheCommandsKeepsTheLLMBlock() throws {
        var config = try ConfigFixtures.parse(LLMTexts.url("https://example.com/v1"))
        config.commands = [CommandEntry(id: "open_finder", app: "Finder")]
        #expect(try ConfigFixtures.parse(config.yaml()).llm == local("https://example.com/v1"))
    }
}
