import Foundation
import HarkCore
import Testing

struct ServerAddressCase: Sendable, CustomTestStringConvertible {
    let name: String
    let config: CommandConfig
    let text: String
    /// Nil when the text is not an address at all.
    let expected: LLMConfig?
    /// Whether the parser takes the result, i.e. whether Settings › Ask may save or test it.
    let accepted: Bool

    var testDescription: String { name }
}

private let work = ProviderProfile(
    name: "work", baseURL: URL(string: "https://api.example.com/v1")!, key: .none, model: .named("gpt-x"))
private let twoProfiles = LLMConfig(provider: "work", profiles: ["local": .local, "work": work])

private func with(_ llm: LLMConfig, _ profile: String, base: String) -> LLMConfig {
    var llm = llm
    llm.profiles[profile]?.baseURL = URL(string: base)!
    return llm
}

/// Settings › Ask writes the address of the profile an ask uses, and nothing else.
let serverAddressCases: [ServerAddressCase] = [
    .init(
        name: "a file with no llm: gets the standard one with the address", config: CommandConfig(),
        text: "http://127.0.0.1:8002/v1", expected: with(.standard, "local", base: "http://127.0.0.1:8002/v1"),
        accepted: true),
    .init(
        name: "trimmed", config: CommandConfig(), text: "  http://127.0.0.1:8002/v1 \n",
        expected: with(.standard, "local", base: "http://127.0.0.1:8002/v1"), accepted: true),
    .init(
        name: "the active profile only", config: CommandConfig(llm: twoProfiles), text: "https://llm.example.org/v1",
        expected: with(twoProfiles, "work", base: "https://llm.example.org/v1"), accepted: true),
    .init(
        name: "plain http to another host is refused by the parser", config: CommandConfig(),
        text: "http://192.168.1.20:8000/v1", expected: with(.standard, "local", base: "http://192.168.1.20:8000/v1"),
        accepted: false),
    .init(
        name: "a user and password are refused by the parser", config: CommandConfig(),
        text: "https://me:pw@example.com/v1", expected: with(.standard, "local", base: "https://me:pw@example.com/v1"),
        accepted: false),
    .init(name: "no scheme", config: CommandConfig(), text: "127.0.0.1:8002/v1", expected: nil, accepted: false),
    .init(name: "not a URL", config: CommandConfig(), text: "mtplx", expected: nil, accepted: false),
    .init(name: "empty", config: CommandConfig(), text: "", expected: nil, accepted: false),
]

@Suite struct ServerAddressTests {
    @Test(arguments: serverAddressCases)
    func theAddressLandsInTheActiveProfile(_ c: ServerAddressCase) {
        let next = c.config.settingServerAddress(c.text)
        #expect(next?.llm == c.expected)
        #expect(next?.commands == c.expected.map { _ in c.config.commands })
        let parsed = next.flatMap { try? CommandConfig.parse(Data($0.yaml().utf8)) }
        #expect((parsed != nil) == c.accepted)
        if c.accepted { #expect(parsed == next) }
    }
}
