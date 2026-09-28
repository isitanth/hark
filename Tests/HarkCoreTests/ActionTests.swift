import Foundation
import HarkCore
import Testing

private let present: Set<String> = [
    "/Applications/Safari.app", "/System/Applications/Safari.app", "/System/Library/CoreServices/Finder.app",
    "/System/Applications/Utilities/Terminal.app", "/Users/me/Applications/My Tool.app",
]

private let locator = ApplicationLocator(home: "/Users/me", exists: { present.contains($0) })

private func app(_ path: String) -> URL {
    URL(filePath: path, directoryHint: .isDirectory)
}

struct LocateCase: Sendable, CustomTestStringConvertible {
    let app: String
    let path: String?

    var testDescription: String { app.isEmpty ? "(empty)" : app }
}

let locateCases: [LocateCase] = [
    .init(app: "Finder", path: "/System/Library/CoreServices/Finder.app"),
    .init(app: "Safari", path: "/Applications/Safari.app"),
    .init(app: "Terminal.app", path: "/System/Applications/Utilities/Terminal.app"),
    .init(app: "Utilities/Terminal", path: "/System/Applications/Utilities/Terminal.app"),
    .init(app: "  My Tool ", path: "/Users/me/Applications/My Tool.app"),
    .init(app: "~/Applications/My Tool.app", path: "/Users/me/Applications/My Tool.app"),
    .init(app: "/System/Library/CoreServices/Finder.app", path: "/System/Library/CoreServices/Finder.app"),
    .init(app: "/Applications/Missing.app", path: nil),
    .init(app: "Frigo", path: nil),
    .init(app: "~root/Applications/My Tool.app", path: nil),
    .init(app: "", path: nil),
    .init(app: "   ", path: nil),
]

@Suite struct ApplicationLocatorTests {
    /// A name is looked for in the folders in order, so /Applications wins over /System/Applications.
    @Test(arguments: locateCases)
    func findsTheAppANameOrPathMeans(_ scenario: LocateCase) {
        #expect(locator.url(for: scenario.app) == scenario.path.map(app))
    }

    /// Every app the bundled commands.yaml names is on this Mac, where the real locator finds it.
    @Test func everyAppInTheBundledDefaultIsFound() throws {
        let config = try CommandConfig.parse(try ConfigFixtures.data("commands.yaml"))
        for command in config.commands {
            #expect(ApplicationLocator().url(for: command.app) != nil, "\(command.app)")
        }
    }
}

@Suite struct ActionTests {
    /// The oracle: what each action type comes to. A new type does not compile until it says.
    private func expected(_ type: ActionType) -> (command: ResolvedCommand, plan: ActionPlan) {
        switch type {
        case .openApp:
            (
                ResolvedCommand(id: "open_finder", action: .openApp, target: "Finder"),
                .openApplication(app("/System/Library/CoreServices/Finder.app"))
            )
        }
    }

    @Test(arguments: ActionType.allCases)
    func everyActionTypeResolvesToItsPlan(_ type: ActionType) {
        let (command, plan) = expected(type)
        #expect(ActionResolver.plan(for: command, locator: locator) == .success(plan))
    }

    @Test(arguments: ActionType.allCases)
    func everyActionTypeRunsItsPlan(_ type: ActionType) async throws {
        let workspace = SwitchableWorkspace(nil)
        let (command, plan) = expected(type)
        #expect(try await ActionRunner(workspace: workspace, locator: locator).run(command) == 0)
        switch plan {
        case .openApplication(let url): #expect(workspace.opened == [url])
        }
    }

    @Test func anAppThatIsNotThereFailsBeforeAnythingOpens() async {
        let workspace = SwitchableWorkspace(nil)
        let command = ResolvedCommand(id: "open_fridge", action: .openApp, target: "Frigo")
        #expect(ActionResolver.plan(for: command, locator: locator) == .failure(.appNotFound("Frigo")))
        await #expect(throws: PipelineFailure.appNotFound("Frigo")) {
            try await ActionRunner(workspace: workspace, locator: locator).run(command)
        }
        #expect(workspace.opened.isEmpty)
        #expect(PipelineFailure.appNotFound("Frigo").code == "app_not_found:Frigo")
    }

    /// Opened, but left behind the app in front: the command asked for the app to be used, so it is not a success.
    @Test func anAppThatStaysBehindIsNotASuccess() async {
        let workspace = SwitchableWorkspace(nil)
        workspace.openBehind()
        await #expect(throws: PipelineFailure.appNotActivated("Finder")) {
            try await ActionRunner(workspace: workspace, locator: locator).run(expected(.openApp).command)
        }
        #expect(workspace.opened.count == 1)
        #expect(PipelineFailure.appNotActivated("Finder").code == "app_not_activated:Finder")
    }

    /// LaunchServices waiting on a first-launch prompt must not keep the pipeline in `acting` for as long as it lasts.
    @Test func anAppStillOpeningAtTheDeadlineTimesOut() async {
        let clock = ManualClock()
        let runner = ActionRunner(
            workspace: NeverOpeningWorkspace(), locator: locator, deadline: .seconds(15), clock: clock)
        let command = expected(.openApp).command
        let run = Task<Int32, any Error> { try await runner.run(command) }
        await clock.waitForSleeps(1)
        clock.advance(by: .seconds(15))
        await #expect(throws: PipelineFailure.actionTimeout) { try await run.value }
    }

    /// A launcher that fails to hand off, or an app that dies at launch: it opened, so it is not `action_launch`.
    @Test func anAppThatQuitsAtOnceSaysSo() async {
        let workspace = SwitchableWorkspace(nil)
        workspace.exitAtOnce()
        await #expect(throws: PipelineFailure.appExited("Finder")) {
            try await ActionRunner(workspace: workspace, locator: locator).run(expected(.openApp).command)
        }
        #expect(PipelineFailure.appExited("Finder").code == "app_exited:Finder")
    }

    @Test func anAppTheSystemWillNotOpenFailsToLaunch() async {
        let workspace = SwitchableWorkspace(nil)
        workspace.refuseToOpen()
        await #expect(throws: PipelineFailure.actionLaunch) {
            try await ActionRunner(workspace: workspace, locator: locator).run(expected(.openApp).command)
        }
    }
}

@Suite struct CommandEditingTests {
    @Test(
        arguments: [
            ("Finder", [], "open_finder"), ("System Settings", [], "open_system_settings"),
            ("/Applications/Utilities/Terminal.app", [], "open_terminal"),
            ("Réglages Système", [], "open_reglages_systeme"),
            ("Finder", ["open_finder"], "open_finder_2"),
            ("Finder", ["open_finder", "open_finder_2"], "open_finder_3"),
            ("?!", [], "open_app"),
        ] as [(String, Set<String>, String)])
    func aNewCommandGetsAReadableUniqueID(_ app: String, _ taken: Set<String>, _ id: String) {
        #expect(CommandEntry.newID(for: app, taken: taken) == id)
    }

    @Test(
        arguments: [
            ("réglages, settings", ["réglages", "settings"]), (" note ,, mes notes ,", ["note", "mes notes"]), ("", []),
            (" , ", []),
        ] as [(String, [String])])
    func theAliasesFieldSplitsOnCommas(_ text: String, _ aliases: [String]) {
        #expect(CommandEntry.aliases(from: text) == aliases)
    }

    /// An app picked on disk is written by name when the name finds that same app, by path when it would not.
    @Test(arguments: [
        ("/System/Library/CoreServices/Finder.app", "Finder"),
        ("/Users/me/Applications/My Tool.app", "My Tool"),
        ("/Volumes/Tools/Finder.app", "/Volumes/Tools/Finder.app"),
        ("/Volumes/Tools/Other.app", "/Volumes/Tools/Other.app"),
    ])
    func aPickedAppIsWrittenByNameWhenTheNameFindsIt(_ path: String, _ written: String) {
        #expect(locator.name(for: URL(filePath: path, directoryHint: .isDirectory)) == written)
    }
}

/// A workspace whose open never answers, as LaunchServices does behind a prompt nobody has clicked.
private struct NeverOpeningWorkspace: Workspace {
    func frontmostApplication() async -> AppIdentity? { nil }
    func activate(_ app: AppIdentity) async -> Bool { false }
    func openApplication(at url: URL) async -> ApplicationOpening {
        await withCheckedContinuation { (_: CheckedContinuation<ApplicationOpening, Never>) in }
    }
}
