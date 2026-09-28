import Foundation
import HarkCore
import Testing

private typealias F = Fixture

/// One press, end to end through the controller, with the real resolver and runner on fakes: what the reducer tables
/// cannot show, that a spoken command opens its app instead of being typed, and what its log line says.
@Suite(.timeLimit(.minutes(1)))
struct CommandPipelineTests {
    private struct StubEngine: TranscriptionEngine {
        let text: String

        func transcribe(_ samples: [Float]) async throws(PipelineFailure) -> Transcript {
            Transcript(raw: text, tier: .small)
        }

        func cancel() async {}
    }

    private static let finder = URL(filePath: "/System/Library/CoreServices/Finder.app", directoryHint: .isDirectory)
    private static let locator = ApplicationLocator(
        home: "/Users/me", exists: { $0 == "/System/Library/CoreServices/Finder.app" })
    private static let table = CommandConfig(
        openVerbs: ["en": ["open"], "fr": ["ouvre"]], fillers: ["en": ["the"], "fr": ["le"]],
        commands: [
            CommandEntry(id: "open_finder", app: "Finder"), CommandEntry(id: "open_fridge", app: "Frigo"),
        ])

    private struct Rig {
        let directory: TemporaryDirectory
        let workspace = SwitchableWorkspace(F.mail)
        let accessibility = FakeAccessibility()
        let pasteboard = FakePasteboard()
        let settings = ResolutionSettings()
        let audio: ScriptedAudioInput
        let controller: PipelineController

        init(
            saying text: String, element: FocusedElement? = nil,
            audio: ScriptedAudioInput = ScriptedAudioInput(summary: F.speech)
        ) throws {
            self.audio = audio
            directory = try TemporaryDirectory()
            if let element { accessibility.set(element: element, for: F.mail.processID) }
            let keystrokes = FakeKeystrokes(target: pasteboard)
            let inserter = TextInserter(
                accessibility: accessibility, pasteboard: pasteboard, keystrokes: keystrokes, workspace: workspace)
            settings.update(commands: CommandPipelineTests.table)
            let environment = PipelineEnvironment(
                workspace: workspace, pasteboard: pasteboard, clock: ManualWallClock(F.pressedAt),
                focus: AXFocusProbe(workspace: workspace, accessibility: accessibility),
                audio: audio, engine: StubEngine(text: text),
                resolver: UtteranceResolver(settings: settings), inserter: inserter,
                actions: ActionRunner(workspace: workspace, locator: CommandPipelineTests.locator))
            controller = PipelineController(
                environment: environment, log: UtteranceLog(directory: directory.url, timeZone: F.paris))
        }

        /// Presses, waits for the probe, releases, and returns the one record written. `whileHeld` runs before the
        /// release, `afterRelease` right after it.
        func press(
            whileHeld: (ScriptedAudioInput) -> Void = { _ in }, afterRelease: (ScriptedAudioInput) -> Void = { _ in }
        ) async throws -> UtteranceRecord {
            var snapshots = controller.snapshots.makeAsyncIterator()
            await controller.triggerDown()
            while let snapshot = await snapshots.next(), snapshot.utterance?.focus == nil {}
            whileHeld(audio)
            await controller.triggerUp()
            afterRelease(audio)
            while let snapshot = await snapshots.next() {
                if snapshot.phase == .idle, let record = snapshot.lastRecord { return record }
            }
            throw CancellationError()
        }
    }

    @Test func aSpokenCommandOpensItsAppAndIsLoggedAsOne() async throws {
        let rig = try Rig(saying: "Ouvre le Finder.")

        let record = try await rig.press()

        #expect(record.resolution == .command && record.actionType == .openApp)
        #expect(record.exitCode == 0 && record.error == nil)
        #expect(record.rawText == "Ouvre le Finder." && record.normalizedText == "ouvre le finder")
        #expect(record.targetApp == "com.apple.mail" && record.modelTier == .small)
        #expect(rig.workspace.opened == [Self.finder])
        #expect(rig.accessibility.insertions.isEmpty && rig.pasteboard.writes.isEmpty)
    }

    /// The limit ends the capture while the key is held; what was said still runs, and the line says it was cut.
    @Test func aCommandCutAtTheLimitStillRunsAndSaysSo() async throws {
        let rig = try Rig(saying: "Ouvre le Finder.", audio: ScriptedAudioInput(summary: F.maxed))

        let record = try await rig.press(whileHeld: { $0.emit(.reachedMaxDuration(F.id, F.maxed)) })

        #expect(record.resolution == .command && record.exitCode == 0 && record.error == "max_duration")
        #expect(rig.workspace.opened == [Self.finder])
    }

    /// The release and the limit at the same moment: the limit lands while the stop is still in flight. Taking it
    /// for the capture transcribed nothing and logged the whole recording as a failure.
    @Test func aReleaseRacingTheLimitKeepsTheRecording() async throws {
        let rig = try Rig(
            saying: "Ouvre le Finder.", audio: ScriptedAudioInput(summary: F.maxed, stopDelay: .milliseconds(100)))

        let record = try await rig.press(afterRelease: { $0.emit(.reachedMaxDuration(F.id, F.maxed)) })

        #expect(record.resolution == .command && record.exitCode == 0 && record.error == "max_duration")
        #expect(rig.workspace.opened == [Self.finder])
    }

    /// No verb first: the words go where text goes, and nothing opens.
    @Test func aSentenceThatNamesAnAppIsStillText() async throws {
        let rig = try Rig(saying: "Finder is slow today.")
        rig.settings.update(insertionMode: .clipboard)

        let record = try await rig.press()

        #expect(record.resolution == .textClipboard && record.actionType == nil && record.exitCode == nil)
        #expect(rig.pasteboard.text == "Finder is slow today.")
        #expect(rig.workspace.opened.isEmpty)
    }

    @Test func anAppThatIsNotOnThisMacFailsWithItsName() async throws {
        let rig = try Rig(saying: "Ouvre le frigo.")

        let record = try await rig.press()

        #expect(record.resolution == .failed && record.error == "app_not_found:Frigo")
        #expect(record.actionType == .openApp && record.exitCode == nil)
        #expect(rig.workspace.opened.isEmpty && rig.pasteboard.writes.isEmpty)
    }

    @Test func anAppTheSystemWillNotOpenFailsToLaunch() async throws {
        let rig = try Rig(saying: "Open the Finder.")
        rig.workspace.refuseToOpen()

        let record = try await rig.press()

        #expect(record.resolution == .failed && record.error == "action_launch" && record.actionType == .openApp)
    }

    @Test func anAppLeftBehindIsLoggedAsSuch() async throws {
        let rig = try Rig(saying: "Ouvre le Finder.")
        rig.workspace.openBehind()

        let record = try await rig.press()

        #expect(record.resolution == .failed && record.error == "app_not_activated:Finder")
        #expect(record.actionType == .openApp && rig.workspace.opened == [Self.finder])
    }

    @Test func anAppThatQuitsAtOnceIsLoggedAsSuch() async throws {
        let rig = try Rig(saying: "Ouvre le Finder.")
        rig.workspace.exitAtOnce()

        let record = try await rig.press()

        #expect(record.resolution == .failed && record.error == "app_exited:Finder" && record.actionType == .openApp)
    }

    /// Where text goes has no say over a command: clipboard-only mode and the fallback off both leave it alone.
    @Test func theInsertionSettingsDoNotApplyToACommand() async throws {
        let rig = try Rig(saying: "Open Finder.")
        rig.settings.update(insertionMode: .clipboard)
        rig.settings.update(clipboardFallback: false)

        let record = try await rig.press()

        #expect(record.resolution == .command && rig.workspace.opened == [Self.finder])
        #expect(rig.pasteboard.writes.isEmpty)
    }

    /// A command runs from a password field too, and its line keeps the field's secret out of the log.
    @Test func aCommandFromAPasswordFieldRunsWithoutItsText() async throws {
        let field = FocusedElement(role: "AXTextField", subrole: FocusedElement.secureTextFieldSubrole)
        let rig = try Rig(saying: "Ouvre le Finder.", element: field)

        let record = try await rig.press()

        #expect(record.resolution == .command && rig.workspace.opened == [Self.finder])
        #expect(record.rawText == nil && record.normalizedText == nil)
    }

    /// commands.yaml reloads between two presses: the second one hears the new table.
    @Test func aReloadedTableTakesEffectOnTheNextPress() async throws {
        let rig = try Rig(saying: "Ouvre le Finder.")
        rig.settings.update(commands: CommandConfig(openVerbs: ["fr": ["lance"]], commands: Self.table.commands))
        rig.settings.update(insertionMode: .clipboard)

        let record = try await rig.press()

        #expect(record.resolution == .textClipboard && rig.workspace.opened.isEmpty)
    }
}
