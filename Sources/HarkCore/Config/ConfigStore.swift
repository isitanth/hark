import CryptoKit
import Foundation
import os

/// SHA-256 of the exact bytes of commands.yaml. A write names the revision it was based on, and is refused if the
/// file on disk has moved on since, so the Settings UI can never overwrite an edit made in a text editor.
public struct ConfigRevision: Sendable, Hashable, CustomStringConvertible {
    /// Lowercase hex.
    public let sha256: String

    public init(of bytes: Data) {
        sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { String(sha256.prefix(12)) }
}

/// Where the config in force came from.
public enum ConfigSource: String, Sendable {
    /// commands.yaml as it is on disk.
    case file
    /// The file on disk is bad; this is `.commands.lastgood.yaml`, the last version that parsed.
    case lastGood
    /// The file on disk is bad and there is no last good copy either. No commands at all — never the bundled
    /// defaults, which could bring back a shell command the user deleted.
    case none
}

public struct ConfigSnapshot: Sendable, Equatable {
    /// What the app acts on.
    public let config: CommandConfig
    public let source: ConfigSource
    /// The bytes currently on disk, valid or not. Nil when the file is missing or unreadable. A write is based on this.
    public let diskRevision: ConfigRevision?
    /// Why the file on disk is not the one in force. Nil when it is.
    public let error: ConfigError?

    public init(config: CommandConfig, source: ConfigSource, diskRevision: ConfigRevision?, error: ConfigError?) {
        self.config = config
        self.source = source
        self.diskRevision = diskRevision
        self.error = error
    }

    /// Running on something other than the file on disk.
    public var isDegraded: Bool { error != nil }

    public static let initial = ConfigSnapshot(config: .empty, source: .none, diskRevision: nil, error: nil)
}

public enum ConfigWriteError: Error, Sendable, Equatable {
    /// The file on disk is not the revision the write was based on. Nothing was written.
    case conflict(expected: ConfigRevision?, found: ConfigRevision?)
    /// The new text does not parse. Nothing was written.
    case invalid(ConfigError)
    /// The file on disk has an error, so the config in force is its last good copy: writing would replace what the
    /// user is in the middle of fixing. Nothing was written.
    case degraded
    case io(errno: Int32)
}

/// Owns commands.yaml: seeds it on first launch, parses it, keeps the last good copy, and hot-reloads it.
///
/// - First launch copies the bundled default into place, and so does a launch that finds an unedited older default.
/// - A valid file becomes the config in force and is copied to `.commands.lastgood.yaml`.
/// - A bad file keeps the previous config in force — on a cold start, the last good copy — and publishes a snapshot
///   with `error` set, which HarkApp turns into the error icon. It also writes an `os.Logger` error, category
///   `config`, with the line and column.
/// - Changes are debounced by 100 ms on the injected clock, so one editor save is one reload, and a reload whose bytes
///   hash the same as the last one publishes nothing.
public actor ConfigStore {
    public nonisolated let snapshots: AsyncStream<ConfigSnapshot>
    public private(set) var current = ConfigSnapshot.initial

    public let fileURL: URL
    public let lastGoodURL: URL
    public let defaultURL: URL?

    private let continuation: AsyncStream<ConfigSnapshot>.Continuation
    private let watcher: any FileWatching
    private let clock: any Clock<Duration>
    private let debounce: Duration

    private var watchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    /// Bumped by every `start()` and `stop()`, so a watch loop from an earlier start is ignored.
    private var watchEpoch = 0
    /// Bumped by every change and by `stop()`; see `changeNoticed`.
    private var generation = 0
    private var hasLoaded = false
    private var hasPublished = false

    static let logger = Logger(subsystem: HarkLog.subsystem, category: "config")

    public init(
        fileURL: URL,
        lastGoodURL: URL,
        defaultURL: URL?,
        watcher: any FileWatching = DispatchFileWatcher(),
        clock: any Clock<Duration> = ContinuousClock(),
        debounce: Duration = .milliseconds(100)
    ) {
        (snapshots, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.fileURL = fileURL
        self.lastGoodURL = lastGoodURL
        self.defaultURL = defaultURL
        self.watcher = watcher
        self.clock = clock
        self.debounce = debounce
    }

    public init(paths: AppPaths, watcher: any FileWatching = DispatchFileWatcher()) {
        self.init(
            fileURL: paths.commands, lastGoodURL: paths.lastGoodCommands, defaultURL: BundledResources.defaultCommands,
            watcher: watcher)
    }

    deinit {
        continuation.finish()
    }

    /// Seeds the file if it is missing, loads it, publishes the first snapshot and starts watching. Idempotent.
    public func start() {
        guard watchTask == nil else { return }
        seedIfMissing()
        // Watching starts before the first read, so an edit made while the file is being read is not missed.
        watchEpoch += 1
        let epoch = watchEpoch
        let changes = watcher.changes(of: fileURL)
        if !load() && !hasPublished { publish(current, force: true) }
        watchTask = Task { [weak self] in
            for await _ in changes {
                await self?.changeNoticed(epoch: epoch)
            }
        }
    }

    /// Reads the file now, outside the debounce. Publishes only if the snapshot changed.
    public func reload() {
        load()
    }

    /// Validates `text`, checks the file on disk is still `base`, then replaces it atomically and makes it the config
    /// in force. `base` nil means "the file must not exist". A file with an error is never written over; a missing one
    /// can be written, since nobody is editing it.
    public func write(_ text: String, basedOn base: ConfigRevision?) throws(ConfigWriteError) {
        guard current.error == nil || current.diskRevision == nil else { throw .degraded }
        let bytes = Data(text.utf8)
        let config: CommandConfig
        do {
            config = try CommandConfig.parse(bytes)
        } catch {
            throw .invalid(error)
        }
        let found: ConfigRevision?
        switch ConfigFileIO.read(fileURL) {
        case .success(let onDisk): found = ConfigRevision(of: onDisk)
        case .failure(let failure) where failure.errno == ENOENT: found = nil
        case .failure(let failure): throw .io(errno: failure.errno)
        }
        guard found == base else { throw .conflict(expected: base, found: found) }
        do {
            try ConfigFileIO.ensureDirectory(fileURL.deletingLastPathComponent())
            try ConfigFileIO.replace(fileURL, with: bytes)
        } catch {
            throw .io(errno: error.errno)
        }
        saveLastGood(bytes)
        hasLoaded = true
        publish(ConfigSnapshot(config: config, source: .file, diskRevision: ConfigRevision(of: bytes), error: nil))
    }

    /// Stops watching. `start()` resumes.
    public func stop() {
        watchEpoch += 1
        generation += 1
        watchTask?.cancel()
        watchTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Watching

    /// Each change restarts the debounce. `generation` is what makes a timer stale: a newer change or `stop()` bumps
    /// it, and a timer that wakes to a different generation does nothing — cancellation alone cannot promise that,
    /// because the timer may already be waiting to re-enter the actor.
    private func changeNoticed(epoch: Int) {
        guard epoch == watchEpoch, watchTask != nil else { return }
        generation += 1
        let expected = generation
        let clock = clock
        let debounce = debounce
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await clock.sleep(for: debounce)
            } catch {
                return
            }
            await self?.debounceElapsed(generation: expected)
        }
    }

    private func debounceElapsed(generation expected: Int) {
        guard expected == generation, watchTask != nil else { return }
        debounceTask = nil
        load()
    }

    // MARK: - Loading

    /// SHA-256 of every bundled default a later schema retired. A commands.yaml still byte-identical to one of them
    /// was never edited, so replacing it with the current default loses nothing; an edited one stays as it is and
    /// reports its version.
    static let retiredDefaults: Set<String> = [
        // Version 1, bundled from P0.2 to M6.0.
        "373cf3f4febd547315392b5be9a3784412e2f0a197130aeafc6ec04c940d0c05",
        // Version 2 as M6.1 shipped it, with the nine fillers that let "notre" open Notes.
        "4b727bba0426cf69a6363cf835eba5a5b2caa70d36df5e95bfe47e2cc0c12a49",
        // Version 2 as M6.9 shipped it on 2026-09-23, where the first app named opened; still on the user's Mac.
        "ba8bf43de18320ed163fc9f5ae76ff2257a67b2e6d0c48edf36d32d1458038d9",
        // Version 2 from 2026-09-24 to M8.2, where the app has to end the sentence.
        "2a36af4860fb64b0644ac93a316a923e971011c54bc3925e5d919a8b64e0a732",
    ]

    /// Creates the directory, then copies the bundled default into place if there is no file, or if the file is a
    /// retired default nobody edited. Only ever at `start()`: a file deleted while running stays deleted.
    private func seedIfMissing() {
        do {
            try ConfigFileIO.ensureDirectory(fileURL.deletingLastPathComponent())
        } catch {
            Self.logger.error("cannot create the config directory: errno \(error.errno, privacy: .public)")
        }
        guard let defaultURL else { return }
        let retired: Bool
        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            guard let existing = ConfigFileIO.contents(fileURL),
                Self.retiredDefaults.contains(ConfigRevision(of: existing).sha256)
            else { return }
            retired = true
        } else {
            retired = false
        }
        guard let bytes = ConfigFileIO.contents(defaultURL) else {
            Self.logger.error("cannot read the bundled default commands.yaml")
            return
        }
        do {
            try ConfigFileIO.replace(fileURL, with: bytes)
            if retired {
                Self.logger.notice("commands.yaml was an unedited older default; replaced by the current one")
            }
        } catch {
            Self.logger.error("cannot seed commands.yaml: errno \(error.errno, privacy: .public)")
        }
    }

    /// Reads and parses the file and publishes what follows from it. Returns whether it published.
    @discardableResult
    private func load() -> Bool {
        let next: ConfigSnapshot
        switch ConfigFileIO.read(fileURL) {
        case .failure(let failure):
            next = fallback(for: ConfigError(.unreadable(errno: failure.errno)), diskRevision: nil)
        case .success(let bytes):
            let revision = ConfigRevision(of: bytes)
            if hasLoaded, revision == current.diskRevision { return false }
            do {
                let config = try CommandConfig.parse(bytes)
                saveLastGood(bytes)
                next = ConfigSnapshot(config: config, source: .file, diskRevision: revision, error: nil)
            } catch {
                next = fallback(for: error, diskRevision: revision)
            }
        }
        hasLoaded = true
        return publish(next)
    }

    /// The file is unusable: keep the config in force, or on a cold start fall back to the last good copy, or to
    /// nothing at all.
    private func fallback(for error: ConfigError, diskRevision: ConfigRevision?) -> ConfigSnapshot {
        Self.logger.error("commands.yaml: \(error.description, privacy: .public)")
        if current.source != .none {
            return ConfigSnapshot(config: current.config, source: .lastGood, diskRevision: diskRevision, error: error)
        }
        if let bytes = ConfigFileIO.contents(lastGoodURL) {
            do {
                let config = try CommandConfig.parse(bytes)
                return ConfigSnapshot(config: config, source: .lastGood, diskRevision: diskRevision, error: error)
            } catch let lastGoodError {
                Self.logger.error("last good copy: \(lastGoodError.description, privacy: .public)")
            }
        }
        return ConfigSnapshot(config: .empty, source: .none, diskRevision: diskRevision, error: error)
    }

    /// Copies `bytes` to the last good path unless they are already there, so the store's own write, which the
    /// directory watcher also sees, settles instead of reloading forever.
    private func saveLastGood(_ bytes: Data) {
        guard ConfigFileIO.contents(lastGoodURL) != bytes else { return }
        do {
            try ConfigFileIO.replace(lastGoodURL, with: bytes)
        } catch {
            Self.logger.error("cannot write the last good copy: errno \(error.errno, privacy: .public)")
        }
    }

    @discardableResult
    private func publish(_ next: ConfigSnapshot, force: Bool = false) -> Bool {
        guard force || next != current else { return false }
        current = next
        hasPublished = true
        continuation.yield(next)
        return true
    }
}
