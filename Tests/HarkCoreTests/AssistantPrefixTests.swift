import Foundation
import HarkCore
import Testing

private typealias F = Fixture

private let mailText = FocusSnapshot(
    app: F.mail, element: FocusedElement(role: "AXTextArea", acceptsSelectedText: true, valueSettable: true))

/// M9.2's path: `assistant:` in commands.yaml, the resolver's branch, and the dictation that becomes the assistant.
@Suite struct AssistantPrefixTests {
    // MARK: commands.yaml

    @Test func aFileWithoutTheBlockUsesTheStandardPrefixes() throws {
        let config = try ConfigFixtures.parse("version: 3\ncommands: []\n")
        #expect(config.assistant == nil)
        #expect(config.effectiveAssistant.prefix == ["hark", "arc"])
    }

    @Test func theBlockIsReadAsWritten() throws {
        let config = try ConfigFixtures.parse("version: 3\nassistant:\n  prefix: [Hark, \"hey hark\", arc]\n")
        #expect(config.assistant?.prefix == ["Hark", "hey hark", "arc"])
    }

    /// An empty list turns the prefix off: nothing on the talk key goes to the assistant.
    @Test func anEmptyListTurnsItOff() throws {
        let config = try ConfigFixtures.parse("version: 3\nassistant:\n  prefix: []\n")
        #expect(config.assistant?.prefix == [])
        #expect(SpokenPrefix(config.effectiveAssistant.prefix).request(in: "Hark, quelle heure") == nil)
    }

    /// A field left null keeps its default, as everywhere else in the file.
    @Test func aNullListKeepsTheStandardPrefixes() throws {
        let config = try ConfigFixtures.parse("version: 3\nassistant:\n  prefix:\n")
        #expect(config.effectiveAssistant.prefix == AssistantConfig.defaultPrefix)
    }

    @Test(arguments: [
        (
            "version: 2\nassistant:\n  prefix: [hark]\n",
            ConfigProblem.unknownKey("assistant", path: "", suggestion: nil)
        ),
        ("version: 3\nassistant:\n  prefx: [hark]\n", .unknownKey("prefx", path: "assistant", suggestion: "prefix")),
        ("version: 3\nassistant:\n  prefix: [\"!!\"]\n", .emptyText(path: "assistant.prefix[0]")),
        ("version: 3\nassistant:\n  prefix: [~]\n", .emptyText(path: "assistant.prefix[0]")),
        ("version: 3\nassistant: [hark]\n", .wrongType(path: "assistant", expected: .mapping)),
    ])
    func aBadBlockIsRefused(_ text: String, _ problem: ConfigProblem) {
        #expect(LLMTexts.error(text)?.problem == problem)
    }

    /// Written back only when the file had it, so Settings never adds a block the user did not write.
    @Test func theBlockRoundTrips() throws {
        var config = CommandConfig(assistant: AssistantConfig(prefix: ["hark", "hey hark", "arc"]))
        let text = config.yaml()
        #expect(text.contains("assistant:\n  prefix: [\"hark\", \"hey hark\", \"arc\"]"))
        #expect(try ConfigFixtures.parse(text) == config)
        config.assistant = nil
        #expect(!config.yaml().contains("assistant:"))
    }

    // MARK: The resolver

    @Test func aPrefixComesBeforeCommandsAndText() async {
        let settings = ResolutionSettings()
        settings.update(
            commands: CommandConfig(
                openVerbs: ["fr": ["ouvre"]], commands: [CommandEntry(id: "open_safari", app: "Safari")]))
        let resolver = UtteranceResolver(settings: settings)
        let asked = await resolver.resolve(Transcript(raw: "Arc, ouvre Safari."), focus: mailText)
        #expect(asked.decision == .ask(request: "ouvre Safari."))
        #expect(asked.normalized == "arc ouvre safari")
        let command = await resolver.resolve(Transcript(raw: "Ouvre Safari."), focus: mailText)
        #expect(command.decision == .command(ResolvedCommand(id: "open_safari", action: .openApp, target: "Safari")))
    }

    @Test func thePrefixAloneIsDiscarded() async {
        let resolver = UtteranceResolver(settings: ResolutionSettings())
        #expect(await resolver.resolve(Transcript(raw: "Hark."), focus: mailText).decision == .discard(.emptyRequest))
    }

    /// What is said in a password field stays dictation, whatever its first word.
    @Test func aSecureFieldNeverGoesToTheAssistant() async {
        let resolver = UtteranceResolver(settings: ResolutionSettings())
        let secure = FocusSnapshot(app: F.mail, element: FocusedElement(role: "AXTextField"), isSecureInput: true)
        #expect(
            await resolver.resolve(Transcript(raw: "Arc en ciel 42"), focus: secure).decision == .copy(.secureField))
    }

    @Test func theFilesPrefixesReplaceTheStandardOnes() async {
        let settings = ResolutionSettings()
        settings.update(commands: CommandConfig(assistant: AssistantConfig(prefix: ["hey hark"])))
        let resolver = UtteranceResolver(settings: settings)
        #expect(
            await resolver.resolve(Transcript(raw: "Hey Hark, hi"), focus: mailText).decision == .ask(request: "hi"))
        #expect(await resolver.resolve(Transcript(raw: "Arc, hi"), focus: mailText).decision == .insert(.axInsert))
    }

    // MARK: The reducer

    private static let heard = Transcript(raw: "Arc, quelle est la capitale du Pérou ?", tier: .small)
    private static let resolving = PipelineState.resolving(F.context(capture: F.speech, transcribeMs: 420), heard)
    private let reducer = PipelineReducer()

    @Test func theDictationBecomesTheAssistant() throws {
        let asking = try reducer.reduce(
            Self.resolving,
            .resolved(
                F.id, normalized: "arc quelle est la capitale du perou",
                .ask(request: "quelle est la capitale du Pérou ?"))
        ).get()
        #expect(asking.effects == [.generate(F.id, instruction: "quelle est la capitale du Pérou ?", selection: nil)])
        #expect(asking.state.phase == .asking)
        #expect(asking.state.context?.intent == .assist(caller: F.mail))
        #expect(asking.state.ask?.instruction == "quelle est la capitale du Pérou ?")
    }

    @Test func aRetrySendsTheRequestNotThePrefix() throws {
        let asking = try reducer.reduce(
            Self.resolving,
            .resolved(F.id, normalized: "arc quelle", .ask(request: "quelle est la capitale du Pérou ?"))
        ).get().state
        let failed = try reducer.reduce(asking, .generationFailed(F.id, .noAnswer, LLMCallSummary(ms: 15_000))).get()
        let retried = try reducer.reduce(failed.state, .askRetry(F.id)).get()
        #expect(retried.effects == [.generate(F.id, instruction: "quelle est la capitale du Pérou ?", selection: nil)])
    }

    /// The line keeps the whole transcript, prefix included, and says it was an ask.
    @Test func theLineKeepsWhatWasSaid() throws {
        let asking = try reducer.reduce(
            Self.resolving,
            .resolved(
                F.id, normalized: "arc quelle est la capitale du perou",
                .ask(request: "quelle est la capitale du Pérou ?"))
        ).get().state
        let reviewing = try reducer.reduce(asking, .generated(F.id, LLMCallSummary(model: F.bonsai, ms: 900))).get()
        let copying = try reducer.reduce(reviewing.state, .askCopy(F.id, "Lima.")).get()
        let record = try #require(try reducer.reduce(copying.state, .copied(F.id)).get().effects.first?.record)
        #expect(record.rawText == "Arc, quelle est la capitale du Pérou ?")
        #expect(record.normalizedText == "arc quelle est la capitale du perou")
        #expect(record.actionType == .ask && record.resolution == .textClipboard && record.error == nil)
        #expect(record.llmModel == F.bonsai && record.targetApp == "com.apple.mail")
    }

    @Test func thePrefixAloneLogsEmptyRequest() throws {
        let done = try reducer.reduce(Self.resolving, .resolved(F.id, normalized: "hark", .discard(.emptyRequest)))
            .get()
        let record = try #require(done.effects.first?.record)
        #expect(record.resolution == .discarded && record.error == "empty_request")
    }
}
