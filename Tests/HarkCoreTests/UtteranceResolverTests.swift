import Foundation
import HarkCore
import Testing

private let settableText = FocusedElement(role: "AXTextArea", acceptsSelectedText: true, valueSettable: true)
private let mailText = FocusSnapshot(app: Fixture.mail, element: settableText)

@Suite struct UtteranceResolverTests {
    @Test func fillsTheNormalizedText() async {
        let resolver = UtteranceResolver(settings: ResolutionSettings())
        let result = await resolver.resolve(Transcript(raw: "  Ouvre le Finder. "), focus: mailText)
        #expect(result.normalized == Normalizer.normalize("  Ouvre le Finder. "))
        #expect(result.normalized != nil)
    }

    @Test func aCommandComesBeforeText() async {
        let settings = ResolutionSettings()
        settings.update(
            commands: CommandConfig(
                openVerbs: ["fr": ["ouvre"]], commands: [CommandEntry(id: "open_finder", app: "Finder")]))
        let resolver = UtteranceResolver(settings: settings)
        let command = await resolver.resolve(Transcript(raw: "Ouvre le Finder."), focus: mailText)
        #expect(command.decision == .command(ResolvedCommand(id: "open_finder", action: .openApp, target: "Finder")))
        #expect(command.normalized == "ouvre le finder")
        #expect(await resolver.resolve(Transcript(raw: "Le Finder."), focus: mailText).decision == .insert(.axInsert))
    }

    @Test func withoutCommandsEverythingIsText() async {
        let resolver = UtteranceResolver(settings: ResolutionSettings())
        #expect(
            await resolver.resolve(Transcript(raw: "Ouvre le Finder."), focus: mailText).decision == .insert(.axInsert))
    }

    @Test func mailTextAreaGetsAXInsertion() async {
        let resolver = UtteranceResolver(settings: ResolutionSettings())
        #expect(await resolver.resolve(Fixture.transcript, focus: mailText).decision == .insert(.axInsert))
    }

    @Test func clipboardModeCopies() async {
        let resolver = UtteranceResolver(settings: ResolutionSettings(.init(insertionMode: .clipboard)))
        #expect(await resolver.resolve(Fixture.transcript, focus: mailText).decision == .copy(.chosen))
    }

    @Test func secureFocusCopies() async {
        let resolver = UtteranceResolver(settings: ResolutionSettings())
        let secure = FocusSnapshot(app: Fixture.mail, element: settableText, isSecureInput: true)
        #expect(await resolver.resolve(Fixture.transcript, focus: secure).decision == .copy(.secureField))
    }

    @Test func theFallbackPreferenceReachesTheDecision() async {
        let settings = ResolutionSettings()
        let resolver = UtteranceResolver(settings: settings)
        let nothingFocused = FocusSnapshot(app: Fixture.mail)
        #expect(await resolver.resolve(Fixture.transcript, focus: nothingFocused).decision == .copy(.noTextField))

        settings.update(clipboardFallback: false)
        #expect(settings.current.clipboardFallback == false)
        #expect(
            await resolver.resolve(Fixture.transcript, focus: nothingFocused).decision
                == .discard(.clipboardFallbackDisabled))
        // A field that takes text is unaffected, other than carrying the flag for a failure.
        #expect(
            await resolver.resolve(Fixture.transcript, focus: mailText).decision
                == .insert(.axInsert, fallback: false))
    }

    @Test func nextResolveSeesAnUpdate() async {
        let settings = ResolutionSettings()
        let resolver = UtteranceResolver(settings: settings)
        #expect(await resolver.resolve(Fixture.transcript, focus: mailText).decision == .insert(.axInsert))

        settings.update(insertionMode: .paste)
        #expect(settings.current.insertionMode == .paste)
        #expect(await resolver.resolve(Fixture.transcript, focus: mailText).decision == .insert(.paste))

        settings.update(apps: ["com.apple.mail": AppOverride(insert: .clipboard)])
        #expect(settings.current == .init(insertionMode: .paste, apps: ["com.apple.mail": .init(insert: .clipboard)]))
        #expect(await resolver.resolve(Fixture.transcript, focus: mailText).decision == .copy(.chosen))
    }
}
