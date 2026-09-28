import Foundation
import HarkCore
import Observation
import os

/// What the Model tab renders and what it calls. It mirrors `DownloadCoordinator` and computes nothing itself.
///
/// It also owns the one decision the tab exists to make: which installed tier the pipeline transcribes with.
/// Selecting a tier builds a `Transcriber` and hands it to the `SwappableTranscriptionEngine` the pipeline was
/// built with; the language picker re-points the same engine without reloading the weights.
///
/// The live text decodes on a second Small `Transcriber` behind its own engine, `partialEngine`, so it never
/// queues behind the final. It follows the setting and Small's installation, not the tier chosen for the final.
@Observable
final class ModelsModel {
    static let selectedTierKey = "HarkModelTier"
    static let languageKey = "HarkTranscriptionLanguage"
    static let useCoreMLKey = "HarkUseCoreML"

    private(set) var states: [ModelTier: ModelInstallState] = [:]
    /// The tier the pipeline is transcribing with, or nil while none is loaded.
    private(set) var loadedTier: ModelTier?
    /// Set when loading the weights failed, so the row can say so rather than silently staying unloaded.
    private(set) var loadFailure: ModelTier?
    /// True while the weights are being loaded and warmed up, which on a cold Core ML encoder is not instant.
    private(set) var isWarmingUp = false
    /// Whether the live text is on, which keeps a second Small resident. Written to the preferences by the caller.
    private(set) var partialTranscript: Bool

    var language: TranscriptionLanguage {
        didSet {
            guard language != oldValue else { return }
            defaults.set(language.rawValue, forKey: Self.languageKey)
            Task { await applyLanguage() }
        }
    }

    /// Whether to run the encoder on the Neural Engine through Core ML.
    ///
    /// Off is the faster choice for dictation, which is why it is the default for a fresh install. Core ML's
    /// encoder is compiled for the whole 30 s window, so it cannot use the `audio_ctx` scaling that makes short
    /// clips cheap: measured on small, a 5.7 s clip took 83 ms with Core ML against 76 ms without, and the gap
    /// widens as clips get shorter. What it buys is power — the Neural Engine draws less than the GPU — at the
    /// cost of an extra download per tier, from 163 MB for small to 1.18 GB for large-v3.
    var useCoreML: Bool {
        didSet {
            guard useCoreML != oldValue else { return }
            defaults.set(useCoreML, forKey: Self.useCoreMLKey)
            Task { await applyCoreML() }
        }
    }

    /// Custom vocabulary, fed to whisper as `initial_prompt`. Per decode, so changing it never reloads the weights.
    var vocabulary: [String] {
        didSet {
            guard vocabulary != oldValue else { return }
            Task {
                await transcriber?.set(vocabulary: vocabulary)
                await partialTranscriber?.set(vocabulary: vocabulary)
            }
        }
    }

    /// False until the first look at the models folder has finished, so "no model loaded" is not reported while the
    /// answer is still being worked out.
    private(set) var hasSettled = false

    let catalog = ModelCatalog.all

    @ObservationIgnored private let store: ModelStore
    @ObservationIgnored private let coordinator: DownloadCoordinator
    @ObservationIgnored private let engine: SwappableTranscriptionEngine
    @ObservationIgnored private let partialEngine: SwappableTranscriptionEngine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifications: any NotificationPoster
    @ObservationIgnored private var transcriber: Transcriber?
    /// Bumped by every load and unload. The engine keeps the last swap it received, and swaps can return out of order:
    /// only the newest one may name the transcriber and the loaded tier.
    @ObservationIgnored private var generation: UInt64 = 0
    /// The load whose warm-up set `isWarmingUp`; an older warm-up that ends later leaves the flag to it.
    @ObservationIgnored private var warming: UInt64 = 0
    /// The live text's Small, kept so language and vocabulary changes reach it; nil while the partial is unloaded.
    @ObservationIgnored private var partialTranscriber: Transcriber?
    /// Whether the partial's Small was built with a Core ML encoder, to tell when the encoder landing calls for a
    /// rebuild.
    @ObservationIgnored private var partialHasEncoder = false
    /// `generation` for the partial engine, which swaps independently of the final's.
    @ObservationIgnored private var partialGeneration: UInt64 = 0

    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "models")

    init(
        store: ModelStore,
        coordinator: DownloadCoordinator,
        engine: SwappableTranscriptionEngine,
        partialEngine: SwappableTranscriptionEngine,
        vocabulary: [String] = [],
        defaults: UserDefaults = .standard,
        notifications: any NotificationPoster = NullNotificationPoster()
    ) {
        self.vocabulary = vocabulary
        self.store = store
        self.coordinator = coordinator
        self.engine = engine
        self.partialEngine = partialEngine
        self.partialTranscript = defaults.object(forKey: DictationPreferences.Key.partialTranscript) as? Bool ?? false
        self.defaults = defaults
        self.notifications = notifications
        self.language =
            defaults.string(forKey: Self.languageKey).flatMap(TranscriptionLanguage.init(rawValue:)) ?? .auto
        // No stored choice yet means this is the first launch with the toggle. Read what is already on disk rather
        // than applying a default, because applying "off" to an existing install would delete encoders the user
        // downloaded on purpose before the setting existed.
        let layout = store.layout
        let encoderOnDisk = ModelTier.allCases.contains {
            FileManager.default.fileExists(atPath: layout.coreMLEncoder(for: $0).path(percentEncoded: false))
        }
        self.useCoreML = defaults.object(forKey: Self.useCoreMLKey) as? Bool ?? encoderOnDisk

        Task { [weak self, coordinator] in
            for await update in await coordinator.updates() {
                self?.states[update.tier] = update.state
                self?.reloadIfSelectionBecameInstalled(update)
                self?.syncPartialIfSmallBecameInstalled(update)
                // Its own task: loading a model warms it up, and the rows must keep updating meanwhile.
                Task { await self?.adoptLoneModel(after: update) }
            }
        }
        Task { [weak self] in await self?.start() }
    }

    func state(for tier: ModelTier) -> ModelInstallState { states[tier] ?? .notInstalled }

    func entry(for tier: ModelTier) -> ModelCatalogEntry { ModelCatalog.entry(for: tier) }

    var selectedTier: ModelTier? {
        defaults.string(forKey: Self.selectedTierKey).flatMap(ModelTier.init(rawValue:))
    }

    /// True when there is anything to purge.
    var hasAnyInstalled: Bool {
        ModelTier.allCases.contains { state(for: $0).phase != .notInstalled }
    }

    // MARK: Actions

    func download(_ tier: ModelTier) {
        Task { await coordinator.start(tier) }
    }

    func pause(_ tier: ModelTier) {
        Task { await coordinator.pause(tier) }
    }

    func cancel(_ tier: ModelTier) {
        Task { await coordinator.cancel(tier) }
    }

    func delete(_ tier: ModelTier) {
        Task { [weak self] in
            guard let self else { return }
            if loadedTier == tier { await unloadCurrent() }
            if tier == .small { await unloadPartial() }
            if let failure = await coordinator.delete(tier) {
                Self.logger.error("delete \(tier.rawValue, privacy: .public): \(failure.code, privacy: .public)")
            }
            if tier == .small { await syncPartial() }
        }
    }

    /// Unloads whatever is in use and deletes every model, including anything in the directory the catalogue
    /// does not account for. The selected tier is forgotten too, so a relaunch does not try to load what is gone.
    func purge() {
        Task { [weak self] in
            guard let self else { return }
            await unloadCurrent()
            await unloadPartial()
            defaults.removeObject(forKey: Self.selectedTierKey)
            if let failure = await coordinator.purge() {
                Self.logger.error("purge failed: \(failure.code, privacy: .public)")
                await syncPartial()
                return
            }
            states = await coordinator.snapshot()
            await syncPartial()
        }
    }

    /// Makes `tier` the one the pipeline uses, and starts warming it immediately.
    func use(_ tier: ModelTier) {
        defaults.set(tier.rawValue, forKey: Self.selectedTierKey)
        Task { [weak self] in await self?.load(tier) }
    }

    /// Turns the live text on or off, loading or freeing its Small now rather than at the next dictation.
    func setPartialTranscript(_ enabled: Bool) {
        guard enabled != partialTranscript else { return }
        partialTranscript = enabled
        Task { [weak self] in await self?.syncPartial() }
    }

    // MARK: Internals

    private func start() async {
        // Before the first refresh, because it decides which files a tier needs to count as installed.
        await store.setCoreMLEnabled(useCoreML)
        defaults.set(useCoreML, forKey: Self.useCoreMLKey)
        await coordinator.refresh()
        states = await coordinator.snapshot()
        defer { hasSettled = true }
        let adopted = await adoptLoneModelIfUnselected()
        if let selected = adopted ?? selectedTier, state(for: selected).phase == .installed {
            await load(selected)
        }
        // After the final's warm-up, so the model the user dictates with is ready first.
        await syncPartial()
    }

    /// After launch, a row landing on installed or not installed can leave a lone model unselected: a purge
    /// followed by a download, the selected tier deleted, a model copied in by hand.
    private func adoptLoneModel(after update: ModelStateUpdate) async {
        guard hasSettled, update.state.phase == .installed || update.state.phase == .notInstalled,
            let tier = await adoptLoneModelIfUnselected()
        else { return }
        await load(tier)
    }

    /// Selects the only installed tier when none is selected, and says so. See `ModelSelectionPolicy`. Returns the
    /// tier it selected, for the caller to load.
    private func adoptLoneModelIfUnselected() async -> ModelTier? {
        let selected = selectedTier
        var inventory: [ModelTier: ModelSelectionPolicy.Inventory] = [:]
        for tier in ModelTier.allCases {
            let hasWeights = await store.installation(for: tier) != nil
            inventory[tier] = .init(phase: state(for: tier).phase, hasWeights: hasWeights)
        }
        // Another update may have selected something while this one was reading the disk.
        guard selectedTier == selected,
            let tier = ModelSelectionPolicy.tierToAdopt(selected: selected, inventory: inventory)
        else { return nil }
        defaults.set(tier.rawValue, forKey: Self.selectedTierKey)
        Self.logger.info("selected \(tier.rawValue, privacy: .public), the only installed model")
        Task { [notifications] in _ = await notifications.post(.modelAutoSelected(tier)) }
        return tier
    }

    /// A model that finishes downloading while it is the selected tier becomes the live one without a second click.
    /// Not before launch has settled: the first refresh reports the selected tier installed, and `start()` loads it
    /// then — a second load here put two whisper contexts in memory at every launch, 2026-09-23.
    private func reloadIfSelectionBecameInstalled(_ update: ModelStateUpdate) {
        guard hasSettled, update.tier == selectedTier, update.state.phase == .installed, loadedTier != update.tier
        else { return }
        Task { [weak self] in await self?.load(update.tier) }
    }

    private func load(_ tier: ModelTier) async {
        generation += 1
        let load = generation
        guard let installation = await store.installation(for: tier) else {
            Self.logger.error("no installation for \(tier.rawValue, privacy: .public)")
            if load == generation { loadFailure = tier }
            return
        }
        // Checked again with no suspension before the swap, so the engine receives the swaps in generation order.
        guard load == generation else { return }
        let transcriber = Transcriber(model: installation, language: language, vocabulary: vocabulary)
        await engine.replace(with: transcriber)
        guard load == generation else { return }
        self.transcriber = transcriber
        loadedTier = tier
        loadFailure = nil
        await publishLoaded()
        // The picker or the vocabulary may have changed while the swap was in flight, when `transcriber` still
        // named the old model.
        await transcriber.set(language: language)
        await transcriber.set(vocabulary: vocabulary)
        Self.logger.info("using \(tier.rawValue, privacy: .public)")
        await warmUp(transcriber, tier: tier, load: load)
    }

    /// Pays the load and the warm-up decode now, rather than inside the user's first utterance.
    ///
    /// It is worth its own step because the first Core ML encoder load is not quick: the first press after
    /// selecting small measured 16.4 s end to end for 4.1 s of speech, nearly all of it this. Doing it here
    /// costs nothing the user is waiting on — the swap has already happened, so a press during the warm-up
    /// simply queues behind it on the transcriber's own serial queue.
    ///
    /// A superseded load must not warm: its engine may already be retired and unloaded, and a context loaded after that
    /// is one nothing frees before quit. The generation is checked with no suspension before `prepare`, so either the
    /// newer load has bumped it and this returns, or `prepare` reaches the transcriber ahead of the newer swap's
    /// unload, which then waits behind it and frees the context.
    private func warmUp(_ transcriber: Transcriber, tier: ModelTier, load: UInt64) async {
        guard load == generation else { return }
        isWarmingUp = true
        warming = load
        defer { if warming == load { isWarmingUp = false } }
        do {
            try await transcriber.prepare()
        } catch {
            Self.logger.error("warm-up failed for \(tier.rawValue, privacy: .public): \(error.code, privacy: .public)")
            if load == generation { loadFailure = tier }
        }
    }

    private func unloadCurrent() async {
        generation += 1
        let unload = generation
        await engine.replace(with: NullTranscriptionEngine(tier: loadedTier ?? .small))
        guard unload == generation else { return }
        transcriber = nil
        loadedTier = nil
        await publishLoaded()
    }

    private func applyLanguage() async {
        await transcriber?.set(language: language)
        await partialTranscriber?.set(language: language)
    }

    /// Carries the toggle through to disk and to the live model.
    ///
    /// Turning it off unloads first, because disabling deletes the encoder files the loaded model is using, then
    /// reloads the same tier on Metal. Turning it on starts fetching the encoder for every tier whose weights are
    /// already in place; each one becomes the live model again once its encoder lands.
    private func applyCoreML() async {
        let selected = selectedTier
        if !useCoreML {
            await unloadCurrent()
            await unloadPartial()
            await store.setCoreMLEnabled(false)
            await coordinator.refresh()
            states = await coordinator.snapshot()
            if let selected, state(for: selected).phase == .installed { await load(selected) }
            await syncPartial()
            return
        }
        await store.setCoreMLEnabled(true)
        await coordinator.refresh()
        states = await coordinator.snapshot()
        for tier in ModelTier.allCases where await store.installation(for: tier) != nil {
            await coordinator.start(tier)
        }
    }

    // MARK: Live text

    /// What the `ModelStore` must refuse to delete: the final's tier, and Small while the partial holds it.
    private func publishLoaded() async {
        var tiers: Set<ModelTier> = []
        if let loadedTier { tiers.insert(loadedTier) }
        if partialTranscriber != nil { tiers.insert(.small) }
        await store.setLoaded(tiers)
    }

    /// Small reaching installed is when the live text can load, and when a Core ML encoder landing on weights the
    /// partial already holds calls for a rebuild. Not before launch has settled: `start()` syncs then.
    private func syncPartialIfSmallBecameInstalled(_ update: ModelStateUpdate) {
        guard hasSettled, update.tier == .small, update.state.phase == .installed else { return }
        Task { [weak self] in await self?.syncPartial() }
    }

    /// Brings the partial engine to what the setting and the disk call for.
    ///
    /// A loaded partial is rebuilt when the encoder's presence changed under it: turning Core ML on fetches the
    /// encoder later and keeps the weights, so the installation alone does not tell the old model from the new.
    /// Not wanted, it swaps in the null engine even when nothing is recorded as loaded, since a superseded load's
    /// transcriber may still sit in the engine.
    private func syncPartial() async {
        partialGeneration += 1
        let sync = partialGeneration
        let small = partialTranscript ? await store.installation(for: .small) : nil
        guard sync == partialGeneration else { return }
        guard let small else {
            await unloadPartial()
            return
        }
        let hasEncoder = small.coreMLEncoder != nil
        if partialTranscriber != nil, partialHasEncoder == hasEncoder { return }
        let transcriber = Transcriber(model: small, language: language, vocabulary: vocabulary, idleUnload: nil)
        await partialEngine.replace(with: transcriber)
        guard sync == partialGeneration else { return }
        partialTranscriber = transcriber
        partialHasEncoder = hasEncoder
        await publishLoaded()
        await transcriber.set(language: language)
        await transcriber.set(vocabulary: vocabulary)
        Self.logger.info("live text on small")
        // As in `warmUp`: a superseded sync must not load a context nothing frees before quit.
        guard sync == partialGeneration else { return }
        do {
            try await transcriber.prepare()
        } catch {
            Self.logger.error("live text warm-up failed: \(error.code, privacy: .public)")
        }
    }

    private func unloadPartial() async {
        partialGeneration += 1
        let unload = partialGeneration
        // Cleared before the swap: a sync started during it must see nothing loaded and build a new Small,
        // not return early on a transcriber the engine no longer holds. The store hears of it only after the
        // swap, so it goes on refusing a delete of Small until the old context is actually retired.
        partialTranscriber = nil
        // The engine's cancel reaches only its current transcriber, so a decode running when the setting goes off
        // is aborted here, before the swap retires it; with none in flight the next `begin()` clears it.
        await partialEngine.cancel()
        await partialEngine.replace(with: NullTranscriptionEngine(tier: .small))
        guard unload == partialGeneration else { return }
        await publishLoaded()
    }
}
