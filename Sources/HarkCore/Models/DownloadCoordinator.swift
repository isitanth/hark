import Foundation
import os

public struct ModelStateUpdate: Sendable, Equatable {
    public let tier: ModelTier
    public let state: ModelInstallState

    public init(tier: ModelTier, state: ModelInstallState) {
        self.tier = tier
        self.state = state
    }
}

/// What the Model tab talks to: one row's worth of state per tier, and the four buttons on it.
///
/// It is deliberately not a delegate. A `@MainActor` observable reads `snapshot()` once and then consumes
/// `updates()`, so the UI never has to be reachable from a background thread.
///
/// Nothing here starts on its own. `init` touches neither the disk nor the network, `refresh()` reads the disk
/// and nothing else, and the downloader is reached only from `start`. That is the whole point of the design: a
/// relaunch with a half-finished download shows Paused and waits to be clicked.
public actor DownloadCoordinator {
    private let store: ModelStore

    private var states: [ModelTier: ModelInstallState]
    private var runs: [ModelTier: Run] = [:]
    private var subscribers: [UUID: AsyncStream<ModelStateUpdate>.Continuation] = [:]

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "downloads")

    /// A tier's in-flight install. `work` is what a pause cancels; `drain` outlives it so the final `paused`
    /// state still reaches the row.
    private struct Run {
        let work: Task<Void, Never>
        let drain: Task<Void, Never>
    }

    public init(store: ModelStore) {
        self.store = store
        states = Dictionary(uniqueKeysWithValues: ModelTier.allCases.map { ($0, .notInstalled) })
    }

    // MARK: Reading

    public func snapshot() -> [ModelTier: ModelInstallState] { states }

    public func state(for tier: ModelTier) -> ModelInstallState { states[tier] ?? .notInstalled }

    /// A stream per subscriber. It opens with the current state of every tier, so a view that subscribes late
    /// does not have to combine a snapshot with a stream to render its first frame.
    public func updates() -> AsyncStream<ModelStateUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ModelStateUpdate>.makeStream()
        subscribers[id] = continuation
        for tier in ModelTier.allCases {
            continuation.yield(ModelStateUpdate(tier: tier, state: state(for: tier)))
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    // MARK: Hydration

    /// Reads the models directory and seeds every row. Call it once, after init, from the UI's task.
    public func refresh() async {
        do {
            try await store.prepare()
        } catch {
            Self.logger.error("model directory unusable: \(error.code, privacy: .public)")
            for tier in ModelTier.allCases { seed(tier, .failed(error)) }
            return
        }
        for (tier, state) in await store.launchStates() { seed(tier, state) }
    }

    // MARK: Buttons

    public func start(_ tier: ModelTier) {
        guard runs[tier] == nil, state(for: tier).canStart else { return }
        let (stream, continuation) = AsyncStream<ModelInstallState>.makeStream()
        let store = self.store
        let work = Task {
            // `install` already emits its own terminal state, so there is nothing to append here.
            _ = await store.install(tier) { continuation.yield($0) }
            continuation.finish()
        }
        let drain = Task {
            for await state in stream { apply(tier, state) }
            runs[tier] = nil
        }
        runs[tier] = Run(work: work, drain: drain)
    }

    /// Stops the download and keeps the resume data. The row lands on `paused`.
    public func pause(_ tier: ModelTier) {
        runs[tier]?.work.cancel()
    }

    /// Stops the download and throws the partial away. The row lands on `notInstalled`.
    public func cancel(_ tier: ModelTier) async {
        await settle(tier)
        await store.discard(tier)
        // Re-read rather than assume: cancelling a tier that is already installed must not blank its row.
        apply(tier, await store.launchState(for: tier))
    }

    /// Nil on success. On a refusal the row is left alone — the model is still installed, and the caller is the
    /// one that shows the alert.
    @discardableResult
    /// Stops every run, then clears the models directory. Every row lands on `notInstalled`.
    public func purge() async -> ModelInstallFailure? {
        for tier in ModelTier.allCases { await settle(tier) }
        do {
            try await store.purge()
        } catch {
            Self.logger.error("purge refused: \(error.code, privacy: .public)")
            return error
        }
        for tier in ModelTier.allCases { apply(tier, .notInstalled) }
        return nil
    }

    public func delete(_ tier: ModelTier) async -> ModelInstallFailure? {
        await settle(tier)
        do {
            try await store.delete(tier)
        } catch {
            Self.logger.error("delete refused: \(error.code, privacy: .public)")
            return error
        }
        apply(tier, .notInstalled)
        return nil
    }

    /// Mirrors what the `Transcriber` holds into the store, which is what makes `delete` able to refuse.
    public func setLoaded(_ tiers: Set<ModelTier>) async {
        await store.setLoaded(tiers)
    }

    /// Cancels anything in flight and waits for the drain, so the caller's own state write is the last one.
    private func settle(_ tier: ModelTier) async {
        guard let run = runs[tier] else { return }
        run.work.cancel()
        await run.drain.value
    }

    // MARK: State

    private func apply(_ tier: ModelTier, _ state: ModelInstallState) {
        let current = self.state(for: tier)
        if current != state, !current.canTransition(to: state) {
            // The store is the authority on what happened, so the state is taken either way; this is the alarm
            // for a store change that the transition table was not updated for.
            Self.logger.error(
                "illegal \(current.phase.rawValue, privacy: .public) -> \(state.phase.rawValue, privacy: .public) for \(tier.rawValue, privacy: .public)"
            )
        }
        publish(tier, state)
    }

    /// Hydration, not a transition: what the disk says at launch has no predecessor to be legal from.
    private func seed(_ tier: ModelTier, _ state: ModelInstallState) {
        publish(tier, state)
    }

    private func publish(_ tier: ModelTier, _ state: ModelInstallState) {
        states[tier] = state
        let update = ModelStateUpdate(tier: tier, state: state)
        for continuation in subscribers.values { continuation.yield(update) }
    }
}
