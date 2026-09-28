import AppKit
import Foundation
import HarkCore
import Observation
import os

/// Mirrors PipelineController snapshots, the config store, permissions and preferences for the views, and owns the
/// capture, hotkey and HUD objects. It gathers facts; HarkCore types turn them into what the views show.
@Observable
final class AppModel {
    enum PrivacyPane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case automation = "Privacy_Automation"
    }

    private(set) var snapshot = PipelineSnapshot(phase: .idle)
    /// The Settings tab on show, so the panel can open Settings on the one that fixes a problem.
    var settingsTab = SettingsTab.general
    private(set) var microphone = MicPermission.status
    private(set) var accessibilityTrusted = AccessibilityPermission.isTrusted
    private(set) var config = ConfigSnapshot.initial
    /// LAST and RECENT, seeded from the log so they survive a relaunch.
    private(set) var feed = RecentFeed()
    private(set) var inputDevices: [AudioInputDevice] = []
    /// What "System default" means right now.
    private(set) var systemDefaultInput: AudioInputDevice?
    /// The device the next press will record from, and why if it is not the one chosen.
    private(set) var inputChoice: InputDeviceChoice?
    /// The last notification Hark tried to post was refused. Learned by posting, since the center only answers
    /// once something is asked of it.
    private(set) var notificationsDenied = false
    /// The app that was in front before Hark's panel took over, and where a Paste from LAST sends the text.
    private(set) var previousApp: AppIdentity?
    /// True while a Paste from LAST is on its way, so the button cannot be pressed twice.
    private(set) var isPasting = false
    /// The RECENT row whose text was just put on the clipboard, for a moment, so the click has an answer.
    private(set) var copiedEntryID: String?
    /// Bumped by every clear of the history, so the Log tab reads the folder again.
    private(set) var historyGeneration = 0
    /// Clicks on RECENT rows so far, so a tick knows whether a later one has replaced it.
    @ObservationIgnored private var copyCount = 0
    /// The display language this process was started in; the catalog is chosen at launch, so a change shows only
    /// after a restart.
    let launchDisplayLanguage: DisplayLanguage
    /// Read from Hark's own domain alone: `array(forKey:)` would merge in the global language list and never be nil.
    var displayLanguage: DisplayLanguage {
        didSet {
            guard displayLanguage != oldValue else { return }
            if let languages = displayLanguage.appleLanguages {
                defaults.set(languages, forKey: DisplayLanguage.defaultsKey)
            } else {
                defaults.removeObject(forKey: DisplayLanguage.defaultsKey)
            }
        }
    }

    var preferences: DictationPreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save(to: defaults)
            resolution.update(insertionMode: preferences.insertionMode)
            resolution.update(clipboardFallback: preferences.clipboardFallback)
            if preferences.inputDeviceUID != oldValue.inputDeviceUID {
                refreshInputDevices()
                Task { [audio, uid = preferences.inputDeviceUID] in await audio.setPreferredDevice(uid: uid) }
            }
            models.vocabulary = preferences.vocabulary
            if preferences.partialTranscript != oldValue.partialTranscript {
                models.setPartialTranscript(preferences.partialTranscript)
                hudModel.liveText = preferences.partialTranscript
                drivePartial(snapshot)
            }
        }
    }

    @ObservationIgnored let controller: PipelineController
    /// The Ask engine: the LLM client, the Keychain, and what the last call to the model server came to.
    let ask: AskModel
    /// commands.yaml's `llm:` as the next ask reads it.
    @ObservationIgnored private let askSettings = AskSettings()
    @ObservationIgnored private var askService: AskService?
    /// The Ask panel: what it shows, and the panel itself.
    @ObservationIgnored let askPanel: AskPanelModel
    /// The Model tab's state. Held here because the engine it drives is the one the pipeline was built with.
    @ObservationIgnored let models: ModelsModel
    /// The live text's own Small, beside the final's engine so a partial never queues behind a final.
    @ObservationIgnored let partialEngine: SwappableTranscriptionEngine
    @ObservationIgnored let paths: AppPaths
    @ObservationIgnored let logReader: LogReader
    @ObservationIgnored private let configStore: ConfigStore
    /// What the resolver reads per utterance: the insertion mode here, the `apps:` table and the commands from
    /// commands.yaml.
    @ObservationIgnored private let resolution: ResolutionSettings
    @ObservationIgnored private let audio: AudioCapture
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let hotkeys = HotkeyBridge()
    @ObservationIgnored private let hud: HUDPanel
    @ObservationIgnored private let hudModel: HUDModel
    /// The live text's loop, on `partialEngine`.
    @ObservationIgnored private let partial: PartialTranscription
    /// The utterance the loop was last told to run for, and the last command sent to it: each command waits for the
    /// one before, so a stop and the next start reach the loop in order.
    @ObservationIgnored private var partialUtterance: UtteranceID?
    @ObservationIgnored private var partialControl: Task<Void, Never>?
    /// Lowers the output volume while Hark records and puts it back after (`HarkLowerOtherAudio`).
    @ObservationIgnored private let ducker: OutputDucker
    /// The last volume call sent to the ducker: each waits for the one before, so a lowering and its restore reach
    /// the actor in the order the capture edges came, and the launch recovery before either.
    @ObservationIgnored private var duckerControl: Task<Void, Never>?
    /// The platform seams, held rather than built inline: the panel's Paste has to go through the same inserter as
    /// the pipeline, or the two would take turns undoing each other's pasteboard restore.
    @ObservationIgnored private let workspace = AppKitWorkspace()
    @ObservationIgnored private let pasteboard = AppKitPasteboard()
    @ObservationIgnored private let focusProbe: AXFocusProbe
    @ObservationIgnored private let inserter: TextInserter
    /// Opens apps for the pipeline and for the Commands tab's Test button.
    @ObservationIgnored private let actions: ActionRunner
    /// One poster for the whole app: it is the notification center's delegate, and one authorization prompt is
    /// enough.
    @ObservationIgnored private let notifications = UserNotificationPoster()
    /// `-HarkDebugIconState <idle|recording|transcribing|armed|error>` pins the icon, for screenshots.
    @ObservationIgnored private let pinnedIcon: MenuBarIconState?
    /// `-HarkDebugPreview panel,settings` opens those at launch, for screenshots: the panel in an ordinary window,
    /// because nothing outside a real click opens a window-style menu bar extra. Launch arguments only.
    @ObservationIgnored let debugPreview: Set<String>

    var health: HealthStatus {
        HealthStatus(
            configError: config.error,
            // Not reported while the models folder is still being read at launch.
            modelLoaded: models.loadedTier != nil || !models.hasSettled,
            microphone: microphone,
            accessibilityTrusted: accessibilityTrusted,
            accessibilityNeeded: insertionNeedsAccessibility,
            // A refusal costs nothing when the user asked for no notification anyway.
            notificationsDenied: notificationsDenied && preferences.notificationStyle != .off,
            llmUnreachable: ask.lastFailure != nil)
    }

    /// Clipboard-only mode with no `apps:` entry that types into an app needs no Accessibility at all.
    private var insertionNeedsAccessibility: Bool {
        preferences.insertionMode != .clipboard || config.config.apps.values.contains { $0.insert != .clipboard }
    }

    var iconState: MenuBarIconState {
        pinnedIcon ?? MenuBarIconState(phase: snapshot.phase, health: health)
    }

    /// True while the onboarding window has never been dismissed and a grant it asks for is missing. Read after
    /// `refreshPermissions()`: at launch the permission poll may not have run yet.
    var needsOnboarding: Bool {
        HealthStatus.showsOnboarding(
            dismissed: defaults.bool(forKey: Self.onboardedKey), microphone: microphone,
            accessibilityTrusted: accessibilityTrusted, accessibilityNeeded: insertionNeedsAccessibility)
    }

    init(paths: AppPaths = .standard(), defaults: UserDefaults = .standard) {
        let preferences = DictationPreferences(defaults: defaults)
        self.paths = paths
        self.defaults = defaults
        self.preferences = preferences
        let stored = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) }
        let storedLanguages = stored?[DisplayLanguage.defaultsKey] as? [String]
        let displayLanguage = DisplayLanguage(appleLanguages: storedLanguages)
        // A language Hark has no catalog for shows as "Same as macOS"; drop it so the next launch does follow macOS.
        if storedLanguages != nil, displayLanguage == .system {
            defaults.removeObject(forKey: DisplayLanguage.defaultsKey)
        }
        self.launchDisplayLanguage = displayLanguage
        self.displayLanguage = displayLanguage
        // `-HarkDebugLogs <folder>` shows another folder's log in the panel and the Log tab, for screenshots of every
        // outcome. Launch arguments only; the pipeline still writes to the real log.
        let readFrom = (defaults.volatileDomain(forName: UserDefaults.argumentDomain)["HarkDebugLogs"] as? String)
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
        logReader = LogReader(directory: readFrom ?? paths.logs)
        audio = AudioCapture(
            policy: InputDevicePolicy(preferredUID: preferences.inputDeviceUID),
            maxDuration: Self.debugMaxDuration(defaults) ?? SampleBuffer.defaultMaxDuration,
            dumpURL: Self.dumpURL(defaults))
        hudModel = HUDModel(level: audio, audio: audio)
        hud = HUDPanel(model: hudModel)
        // One engine for the life of the app; the Model tab re-points it when the selected tier changes.
        let engine = SwappableTranscriptionEngine()
        let partialEngine = SwappableTranscriptionEngine()
        self.partialEngine = partialEngine
        partial = PartialTranscription(engine: partialEngine, tail: audio)
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        debugPreview = Set(((arguments["HarkDebugPreview"] as? String) ?? "").split(separator: ",").map(String.init))
        // A preview launch is a second process on the same defaults: the lowered-volume record it would find is the
        // running Hark's, live, so it neither recovers it nor gives it back at quit. It never records either.
        let ownsVolume = debugPreview.isEmpty
        // Before anything records: a volume a crash or a forced exit left lowered comes back first.
        // UserDefaults is documented thread-safe but not marked Sendable; the actor shares the main actor's instance.
        nonisolated(unsafe) let sharedDefaults = defaults
        let ducker = OutputDucker(volume: CoreAudioOutputVolume(), defaults: sharedDefaults)
        self.ducker = ducker
        if ownsVolume { duckerControl = Task { await ducker.recoverAtLaunch() } }
        hudModel.liveText = preferences.partialTranscript
        let store = ModelStore(layout: ModelLayout(paths: paths), downloader: .standard)
        models = ModelsModel(
            store: store, coordinator: DownloadCoordinator(store: store), engine: engine,
            partialEngine: partialEngine,
            vocabulary: preferences.vocabulary, defaults: defaults, notifications: notifications)
        configStore = ConfigStore(paths: paths)
        resolution = ResolutionSettings(
            .init(insertionMode: preferences.insertionMode, clipboardFallback: preferences.clipboardFallback))
        let accessibility = SystemAccessibility()
        focusProbe = AXFocusProbe(workspace: workspace, accessibility: accessibility)
        inserter = TextInserter(
            accessibility: accessibility, pasteboard: pasteboard, keystrokes: CGEventKeystrokeSynthesizer(),
            workspace: workspace)
        actions = ActionRunner(workspace: workspace)
        let ask = AskModel()
        self.ask = ask
        let environment = PipelineEnvironment(
            workspace: workspace, pasteboard: pasteboard, focus: focusProbe, audio: audio, engine: engine,
            resolver: UtteranceResolver(settings: resolution), inserter: inserter, actions: actions,
            asker: AskEngine(client: ask.client, settings: askSettings))
        controller = PipelineController(environment: environment, log: UtteranceLog(directory: paths.logs))
        askPanel = AskPanelModel(controller: controller, workspace: workspace, pasteboard: pasteboard)
        pinnedIcon = defaults.string(forKey: "HarkDebugIconState").flatMap(MenuBarIconState.init(rawValue:))
        // The volume first, so a quit past the deadline still gives it back; then the pipeline, so the utterance in
        // flight writes its line; then the engines, so nothing loads again.
        // The actor runs this end after the calls already queued on it; a lowering still waiting in the chain behind
        // it would leave its record, which the next launch recovers.
        HarkAppDelegate.beforeQuit = { [controller, partialEngine, ducker] in
            if ownsVolume { await ducker.end() }
            await controller.quit()
            Logger(subsystem: "com.anthonychambet.hark", category: "lifecycle").notice("the pipeline is idle")
            await engine.shutdown()
            await partialEngine.shutdown()
        }

        Task { [weak self, controller] in
            for await snapshot in controller.snapshots {
                self?.apply(snapshot)
            }
        }
        Task { [weak self, controller] in
            for await update in controller.askUpdates {
                self?.askPanel.update(update)
            }
        }
        Task { [weak self, partial] in
            for await result in partial.results {
                self?.hudModel.show(result)
            }
        }
        Task { [weak self, configStore, resolution, askSettings] in
            await configStore.start()
            for await snapshot in configStore.snapshots {
                self?.config = snapshot
                askSettings.update(snapshot.config.effectiveLLM)
                self?.askPanel.configure(snapshot.config.effectiveLLM)
                // The last good config, so a broken file keeps the overrides and commands that were in force.
                resolution.update(apps: snapshot.config.apps)
                resolution.update(commands: snapshot.config)
            }
        }
        Task { [weak self, logReader] in
            let page = await Task.detached { logReader.read(limit: RecentFeed.retained) }.value
            self?.feed.seed(page.entries)
        }
        Task { [weak self] in
            for await _ in AudioDevices.changes() {
                self?.refreshInputDevices()
            }
        }
        previousApp = Self.otherApp(NSWorkspace.shared.frontmostApplication)
        Task { [weak self] in
            for await note in NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didActivateApplicationNotification)
            {
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let app = Self.otherApp(app) else { continue }
                self?.previousApp = app
            }
        }
        Task { [weak self] in
            for await note in NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didTerminateApplicationNotification)
            {
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let pid = app?.processIdentifier, self?.previousApp?.processID == pid else { continue }
                self?.previousApp = nil
            }
        }
        let service = AskService { [weak self] in self?.previousApp }
        service.onAsk = { [weak self] text, caller in self?.startAsk(text, caller: caller) }
        askService = service
        askPanel.preflight = { [weak self] in await self?.preflight() }
        HarkAppDelegate.servicesProvider = service
        refreshInputDevices()
        Task { [audio] in await audio.prepare() }
        hotkeys.start(driving: controller, onLatchChange: { [hudModel] in hudModel.setLatched($0) })
        Task { [weak self] in await self?.pollPermissions() }
    }

    func refreshPermissions() {
        microphone = MicPermission.status
        accessibilityTrusted = AccessibilityPermission.isTrusted
        // Asking the center what it already decided; it never prompts, so a grant made in System Settings takes
        // the warning down the next time the panel opens rather than after the next clipboard copy.
        Task { [notifications] in
            guard let denied = await notifications.isDenied() else { return }
            notificationsDenied = denied
        }
    }

    func refreshInputDevices() {
        let devices = AudioDevices.inputDevices()
        let defaultID = AudioDevices.defaultInputDeviceID()
        inputDevices = devices
        systemDefaultInput = defaultID.flatMap { id in devices.first { $0.id == id } }
        inputChoice = InputDevicePolicy(preferredUID: preferences.inputDeviceUID)
            .choose(from: devices, systemDefault: defaultID, mode: .pushToTalk)
    }

    func openPrivacySettings(_ pane: PrivacyPane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Notifications are not in the Privacy pane: they have their own, which opens on Hark's row.
    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// The Paste button under LAST. The text is already on the clipboard; this puts it where the user was before
    /// they opened the panel, the same way a dictation would have. It is not an utterance, so it writes no log line.
    ///
    /// `entry` is the one the button was drawn for, and `dismiss` closes the window it was drawn in.
    func pasteLast(_ entry: LogEntry, dismiss: @escaping () -> Void) {
        // A dictation that landed between the button being drawn and being pressed owns the clipboard now.
        guard !isPasting, canPaste(entry), feed.last?.id == entry.id, let text = entry.rawText,
            let target = previousApp
        else { return }
        isPasting = true
        Task { [workspace, focusProbe, inserter] in
            defer { isPasting = false }
            // The panel is in front of the field the text is for, and it goes first: activating the other app
            // would dismiss it anyway, but not this early.
            dismiss()
            guard await workspace.activateAndWait(target, timeout: Self.activationTimeout) else {
                Self.logger.error("\(target.logName, privacy: .public) did not come forward; nothing was pasted")
                return
            }
            let focus = await focusProbe.probe()
            // The text is on the clipboard already, so there is nothing to fall back to: either it goes into the
            // field or the user pastes it themselves.
            guard let plan = FocusResolver.pastePlan(focus: focus, apps: config.config.apps) else {
                Self.logger.error("nothing in \(target.logName, privacy: .public) takes text; nothing was pasted")
                return
            }
            // The clipboard already holds this text — that is what a Paste from LAST is — so there is nothing to
            // take back if the paste lands nowhere. It goes in at a caret like any dictation, so it gets the same
            // leading space the field asks for.
            try? await inserter.insert(text, plan: plan, focus: focus, clipboardFallback: true)
        }
    }

    /// True when LAST is the utterance just spoken, its text is on the clipboard, and there is somewhere to put it.
    var canPasteLast: Bool {
        guard let entry = feed.last, canPaste(entry), let app = previousApp else { return false }
        return NSRunningApplication(processIdentifier: app.processID)?.isTerminated == false
    }

    /// The text of `entry` is what the clipboard holds: it was copied by this run, not read back from the log.
    /// An ask's line holds the instruction, and the clipboard its answer: there is nothing of the line to paste.
    private func canPaste(_ entry: LogEntry) -> Bool {
        guard entry.id.hasPrefix(LogEntry.liveIDPrefix), entry.resolution == .textClipboard,
            entry.actionType != LoggedAction.askRawValue
        else { return false }
        return !(entry.rawText ?? "").isEmpty
    }

    /// Deletes the dictation history, once the view has asked for confirmation, and empties LAST and RECENT from
    /// whatever is left on disk: nothing, unless a file could not be deleted.
    func clearHistory() {
        do {
            try LogHistory.clear(in: logReader.directory)
        } catch {
            Self.logger.error("history not fully cleared: \(error.localizedDescription, privacy: .public)")
        }
        var cleared = RecentFeed()
        cleared.seed(logReader.read(limit: RecentFeed.retained).entries)
        feed = cleared
        copiedEntryID = nil
        historyGeneration += 1
    }

    /// A RECENT row, clicked: its text goes on the clipboard, as an ordinary copy the user keeps.
    func copyToClipboard(_ entry: LogEntry) {
        guard let text = entry.rawText, !text.isEmpty else { return }
        copyCount += 1
        let copy = copyCount
        Task { [pasteboard] in
            guard await pasteboard.writeText(text) else { return }
            copiedEntryID = entry.id
            try? await Task.sleep(for: Self.copiedFeedback)
            // A second click on the same row starts its own two seconds; this one no longer owns the tick.
            if copyCount == copy { copiedEntryID = nil }
        }
    }

    /// Long enough for an app that is slow to come forward, short enough that a dead one does not hang the button.
    private static let activationTimeout = Duration.seconds(2)
    private static let copiedFeedback = Duration.seconds(2)

    /// `app` unless it is Hark itself: the panel opening is not the user changing apps.
    private static func otherApp(_ app: NSRunningApplication?) -> AppIdentity? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return AppIdentity(app)
    }

    /// The file, or its folder once the file is gone: Finder selects nothing for a path that does not exist.
    func revealCommandsFile() {
        let file = paths.commands
        let exists = FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
        NSWorkspace.shared.activateFileViewerSelecting([exists ? file : file.deletingLastPathComponent()])
    }

    /// Replaces the command table of `snapshot` — the config the change was made against — and writes the result.
    /// The store refuses if the file moved on since that snapshot or has an error, so an edit made in a text editor
    /// is never silently replaced; after a conflict it reads the file again at once, so the tab shows what is there.
    func saveCommands(_ commands: [CommandEntry], basedOn snapshot: ConfigSnapshot) async -> ConfigWriteError? {
        var next = snapshot.config
        next.commands = commands
        do throws(ConfigWriteError) {
            try await configStore.write(next.yaml(), basedOn: snapshot.diskRevision)
            return nil
        } catch {
            if case .conflict = error { await configStore.reload() }
            return error
        }
    }

    /// Why an address typed in Settings › Ask was not saved or tested.
    enum ServerAddressProblem: Error, Equatable {
        /// Not an absolute URL at all.
        case notAnAddress
        /// The parser or the store refused it: plain http to another host, a user and password in it, a conflict.
        case write(ConfigWriteError)
    }

    /// The active profile with `text` as its base URL, if commands.yaml would take it: what Test connection checks
    /// before anything is saved, so a key never goes to an address the file would refuse.
    func profile(forServerAddress text: String) -> Result<ProviderProfile, ServerAddressProblem> {
        guard let next = config.config.settingServerAddress(text) else { return .failure(.notAnAddress) }
        do throws(ConfigError) {
            let parsed = try CommandConfig.parse(Data(next.yaml().utf8))
            guard let profile = parsed.effectiveLLM.activeProfile else { return .failure(.notAnAddress) }
            return .success(profile)
        } catch {
            return .failure(.write(.invalid(error)))
        }
    }

    /// Writes `text` as the active profile's base URL into commands.yaml, based on the config on show, as the
    /// Commands tab writes its table.
    func saveServerAddress(_ text: String) async -> ServerAddressProblem? {
        let snapshot = config
        guard let next = snapshot.config.settingServerAddress(text) else { return .notAnAddress }
        do throws(ConfigWriteError) {
            try await configStore.write(next.yaml(), basedOn: snapshot.diskRevision)
            return nil
        } catch {
            if case .conflict = error { await configStore.reload() }
            return .write(error)
        }
    }

    /// The Test button: the command runs now, outside the pipeline. Nothing was said, so nothing is logged.
    func run(_ command: CommandEntry) async -> PipelineFailure? {
        do throws(PipelineFailure) {
            _ = try await actions.run(command.resolved)
            return nil
        } catch {
            return error
        }
    }

    func finishOnboarding() {
        defaults.set(true, forKey: Self.onboardedKey)
    }

    private static let onboardedKey = "HarkOnboarded"
    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "insertion")

    private func apply(_ snapshot: PipelineSnapshot) {
        if let record = snapshot.lastRecord, record != self.snapshot.lastRecord {
            feed.append(LogEntry(record: record))
            announce(record)
        }
        if snapshot.phase == .capturing, self.snapshot.phase != .capturing {
            // Polling stops once both permissions are granted; a press is when a revoked grant starts to matter.
            refreshPermissions()
            let enabled = preferences.lowerOtherAudio
            let input = inputChoice?.device.transport
            let systemDefault = systemDefaultInput?.transport
            let previous = duckerControl
            duckerControl = Task { [ducker] in
                await previous?.value
                await ducker.begin(enabled: enabled, input: input, systemDefault: systemDefault)
            }
        }
        // Every end of a capture leaves `.capturing`: key up, the limit, a cancel, a failure. The sound comes back
        // then, while a long clip may still be transcribing. The setting turned off meanwhile still restores.
        if snapshot.phase != .capturing, self.snapshot.phase == .capturing {
            let previous = duckerControl
            duckerControl = Task { [ducker] in
                await previous?.value
                await ducker.end()
            }
        }
        recordAsk(snapshot)
        self.snapshot = snapshot
        hudModel.update(snapshot)
        hud.setVisible(hudModel.state != .hidden)
        askPanel.update(snapshot)
        drivePartial(snapshot)
    }

    /// Runs the live text's loop while an utterance is captured with the setting on, and stops it on whatever leaves
    /// `.capturing`: key up, the limit, a cancel, a failure. The stop aborts a partial still decoding, so the final
    /// shares the hardware with at most one partial: 18 ms when the stop cancels it, as it typically does, and 37 ms
    /// when the stop is lost (docs/acceptance/M7.md, row 5).
    /// An ask has no live line: the HUD that would show it stays down.
    private func drivePartial(_ snapshot: PipelineSnapshot) {
        let live = preferences.partialTranscript && snapshot.phase == .capturing
        let wanted = live && snapshot.utterance?.intent.isAsk == false ? snapshot.utterance?.id : nil
        guard wanted != partialUtterance else { return }
        partialUtterance = wanted
        let previous = partialControl
        partialControl = Task { [partial] in
            await previous?.value
            if let wanted {
                await partial.start(wanted)
            } else {
                await partial.stop()
            }
        }
    }

    /// `-HarkDebugPreview hud`, `hud-latched`, `hud-limit` or `hud-partial`: the HUD pinned in one state, with fixed
    /// bars and, for the last, a sample live line, for
    /// screenshots. Snapshots do not move or hide it.
    func showHUDPreview() {
        let pinned: (state: HUDState, time: String)? =
            if debugPreview.contains("hud-limit") {
                (.transcribing(.limitReached), ElapsedTime.text(milliseconds: 1_800_000))
            } else if debugPreview.contains("hud-partial") {
                (.listening(handsFree: false), "0:42")
            } else if debugPreview.contains("hud-latched") {
                (.listening(handsFree: true), "1:23")
            } else if debugPreview.contains("hud") {
                (.listening(handsFree: false), "1:23")
            } else {
                nil
            }
        guard let pinned else { return }
        // A sample in the preview's language, long enough to show the head cut; not a catalog string.
        let french = Locale.preferredLanguages.first?.hasPrefix("fr") == true
        let line: String? =
            !debugPreview.contains("hud-partial")
            ? nil
            : french
                ? "je voudrais faire le point sur la réunion de ce matin avant que tout le monde parte en week-end"
                : "I wanted to summarize this morning's meeting before everyone leaves for the weekend"
        hudModel.pin(pinned.state, time: pinned.time, line: line)
        hud.setVisible(true)
    }

    /// Services › Ask Hark: the ask starts as a capture, and the panel opens on its first snapshot. A blank selection
    /// ends at once with its line and no panel, so the caller is brought back here.
    private func startAsk(_ text: String, caller: AppIdentity?) {
        let selection = SelectionSnapshot(text: text, caller: caller)
        Task { [controller, workspace] in
            await controller.triggerDown(intent: .ask(selection))
            guard selection.isBlank, let caller else { return }
            _ = await workspace.activateAndWait(caller, timeout: Self.activationTimeout)
        }
    }

    /// The pre-flight: `GET /models` while the user speaks, so a stopped server says so before the instruction is
    /// spent on it. An ask is the user's request, so a cloud profile is checked too. The result feeds the health row.
    private func preflight() async -> LLMProbeResult? {
        guard let profile = config.config.effectiveLLM.activeProfile else { return nil }
        return await ask.test(profile)
    }

    /// What an ask came to, for the panel's health row, as Test connection's result would.
    private func recordAsk(_ snapshot: PipelineSnapshot) {
        guard let stage = snapshot.ask?.stage, stage != self.snapshot.ask?.stage else { return }
        switch stage {
        case .reviewing:
            if let model = snapshot.utterance?.llmModel { ask.record(.connected(model: model)) }
        case .failed(let failure):
            ask.record(.failed(failure))
        case .generating:
            break
        }
    }

    /// `-HarkDebugPreview ask…`: the Ask panel pinned in one state, for screenshots.
    func showAskPreview() {
        askPanel.configure(config.config.effectiveLLM)
        askPanel.showPreview(debugPreview)
    }

    /// Text on the clipboard, a capture cut at the length limit, a recording cancelled by a change of microphone and
    /// a voice command that failed are the outcomes with nothing on screen to show for them, so they are what Hark
    /// says out loud. The first one asks the user for permission to.
    private func announce(_ record: UtteranceRecord) {
        let style = preferences.notificationStyle
        guard
            let content = ClipboardNotice.content(for: record, style: style)
                ?? CaptureLimitNotice.content(for: record, style: style)
                ?? InputChangeNotice.content(for: record, style: style)
                ?? CommandFailureNotice.content(for: record, style: style)
        else { return }
        Task { [notifications] in
            let delivery = await notifications.post(content)
            switch delivery {
            case .denied: notificationsDenied = true
            case .delivered: notificationsDenied = false
            // Nothing to tell the user about a post that failed for its own reasons; it is in the log.
            case .failed: break
            }
        }
    }

    /// The onboarding window asks for the permissions; this picks up grants made in System Settings. It stops once
    /// both are in place, and the panel and the onboarding window refresh on their own when they appear.
    private func pollPermissions() async {
        refreshPermissions()
        while microphone != .granted || !accessibilityTrusted {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            refreshPermissions()
        }
    }

    /// `-HarkDebugMaxDuration <seconds>`: the length limit in seconds instead of 30 minutes, so the limit's HUD row
    /// can be checked in 20 s. Launch arguments only.
    private static func debugMaxDuration(_ defaults: UserDefaults) -> Duration? {
        let value = defaults.volatileDomain(forName: UserDefaults.argumentDomain)["HarkDebugMaxDuration"]
        let seconds = (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0) }
        guard let seconds, seconds > 0 else { return nil }
        return .seconds(seconds)
    }

    /// Launch-argument domain only, so a stray `defaults write` cannot leave the dump on.
    private static func dumpURL(_ defaults: UserDefaults) -> URL? {
        #if HARK_DEBUG_AUDIO
            let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            return (arguments["HarkDumpAudio"] as? String)?.uppercased() == "YES"
                ? URL(filePath: "/tmp/hark-last.wav") : nil
        #else
            nil
        #endif
    }
}
