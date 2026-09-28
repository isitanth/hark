import Foundation
import os

/// The model directory: what is installed, what is half-downloaded, and the steps that turn one into the other.
///
/// The store owns files and nothing else. It has no reference to the `Transcriber`, so it cannot tell whether a
/// tier's weights are currently mapped — the owner of both tells it, through `setLoaded`, and `delete`
/// refuses on that basis. That injection is the only piece of state here that does not come from the disk.
public actor ModelStore {
    public nonisolated let layout: ModelLayout

    private let catalog: ModelCatalogTable
    private let downloader: any ModelDownloading
    private let launcher: any ProcessLaunching
    private let diskSpace: DiskSpacePolicy
    private let fileManager = FileManager.default

    /// Tiers whose staged bytes were swept at startup. They read `interrupted` until the user starts them again.
    private var orphaned: Set<ModelTier> = []
    private var loadedTiers: Set<ModelTier> = []
    private var prepared = false
    /// Whether a tier's Core ML encoder is part of what installing it means. See `setCoreMLEnabled(_:)`.
    private var coreMLEnabled: Bool

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "model-store")

    /// `ditto` on the 1.1 GB large-v3 encoder is tens of seconds on the slowest supported disk. Ten minutes is
    /// not a performance budget, it is the point at which the process is assumed wedged rather than working.
    private static let extractionTimeout = Duration.seconds(600)
    private static let ditto = URL(filePath: "/usr/bin/ditto")

    /// Lets a swept orphan be attributed to its tier without reparsing file names.
    private let tierByFile: [String: ModelTier]

    public init(
        layout: ModelLayout,
        downloader: any ModelDownloading,
        launcher: any ProcessLaunching = SystemProcessLauncher(),
        diskSpace: DiskSpacePolicy = DiskSpacePolicy(),
        catalog: ModelCatalogTable = .standard,
        coreMLEnabled: Bool = true
    ) {
        self.coreMLEnabled = coreMLEnabled
        self.layout = layout
        self.downloader = downloader
        self.launcher = launcher
        self.diskSpace = diskSpace
        self.catalog = catalog
        var files: [String: ModelTier] = [:]
        for entry in catalog.all {
            for artifact in entry.artifacts { files[artifact.file] = entry.tier }
        }
        tierByFile = files
    }

    // MARK: Startup

    /// Creates the directories, excludes them from backup, and sweeps crash orphans. Idempotent.
    public func prepare() throws(ModelInstallFailure) {
        guard !prepared else { return }
        do {
            try fileManager.createDirectory(at: layout.staging, withIntermediateDirectories: true)
        } catch {
            throw .filesystem(error.localizedDescription)
        }
        excludeFromBackup()
        orphaned = sweepStagingOrphans()
        prepared = true
    }

    /// Several gigabytes of files that a download reproduces exactly. Time Machine should not carry them.
    private func excludeFromBackup() {
        var url = layout.models
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            // A volume that does not carry the flag is not a reason to refuse to install models.
            Self.logger.warning("could not exclude models from backup: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A staged artefact with no `.resume` sidecar is a partial that outlived its process. The bytes are
    /// unverifiable and unresumable, so they go, and the tier reports `interrupted` rather than silently restarting.
    private func sweepStagingOrphans() -> Set<ModelTier> {
        let path = layout.staging.path(percentEncoded: false)
        guard let names = try? fileManager.contentsOfDirectory(atPath: path) else { return [] }
        var swept: Set<ModelTier> = []
        for name in names where !name.hasSuffix(ModelLayout.resumeSuffix) {
            let sidecar = layout.staging.appending(path: name + ModelLayout.resumeSuffix, directoryHint: .notDirectory)
            guard !exists(sidecar) else { continue }
            try? fileManager.removeItem(at: layout.staging.appending(path: name, directoryHint: .notDirectory))
            if let tier = tierByFile[name] { swept.insert(tier) }
            Self.logger.warning("swept crash orphan \(name, privacy: .public)")
        }
        return swept
    }

    /// The row's state at launch. Never `downloading`: see `ModelInstallState.atLaunch`.
    public func launchState(for tier: ModelTier) -> ModelInstallState {
        ModelInstallState.atLaunch(
            installed: isInstalled(tier),
            resume: resumeRecord(for: tier)?.progress,
            stagedFile: orphaned.contains(tier))
    }

    public func launchStates() -> [ModelTier: ModelInstallState] {
        Dictionary(uniqueKeysWithValues: ModelTier.allCases.map { ($0, launchState(for: $0)) })
    }

    // MARK: Inventory

    public func isInstalled(_ tier: ModelTier) -> Bool {
        artifacts(for: tier).allSatisfy { exists(destination(for: $0, tier: tier)) }
    }

    /// What installing `tier` fetches: its weights, and its Core ML encoder only while that is enabled.
    private func artifacts(for tier: ModelTier) -> [ModelArtifact] {
        let entry = catalog.entry(tier)
        return coreMLEnabled ? entry.artifacts : [entry.weights]
    }

    /// Turns the Core ML encoder on or off for every tier.
    ///
    /// whisper.cpp has no switch for this: it uses an encoder if and only if one exists at the path it derives
    /// from the weights. So the file is the setting. Disabling removes every installed encoder and Core ML's
    /// compiled copy of them — which is also what frees the space — and enabling means the next install of a
    /// tier fetches its encoder, including a tier whose weights are already in place.
    ///
    /// The caller must unload the transcriber before disabling, since this deletes files a loaded model uses.
    public func setCoreMLEnabled(_ enabled: Bool) {
        coreMLEnabled = enabled
        guard !enabled else { return }
        for tier in ModelTier.allCases where catalog.entry(tier).coreMLEncoder != nil {
            try? fileManager.removeItem(at: encoderURL(for: tier))
        }
        clearCoreMLCache()
        Self.logger.info("core ml disabled; encoders removed")
    }

    public var isCoreMLEnabled: Bool { coreMLEnabled }

    /// What the `Transcriber` consumes, or nil when the weights are not on disk.
    public func installation(for tier: ModelTier) -> ModelInstallation? {
        let weights = weightsURL(for: tier)
        guard exists(weights) else { return nil }
        let encoder = encoderURL(for: tier)
        return ModelInstallation(tier: tier, weights: weights, coreMLEncoder: exists(encoder) ? encoder : nil)
    }

    /// The tiers the `Transcriber`s currently hold: the final's and, while the live text is on, a Small. Set by
    /// whoever owns them; empty when nothing is loaded.
    public func setLoaded(_ tiers: Set<ModelTier>) {
        loadedTiers = tiers
    }

    public var loaded: Set<ModelTier> { loadedTiers }

    // MARK: Install

    /// Runs one tier to completion and returns the state it ended in.
    ///
    /// Cancelling the task that calls this is how a pause happens: the downloader returns `.paused`, the resume
    /// data is written to the sidecar, and the result is `.paused` rather than a thrown `CancellationError`.
    public func install(
        _ tier: ModelTier,
        onState: @escaping @Sendable (ModelInstallState) -> Void
    ) async -> ModelInstallState {
        do {
            try prepare()
        } catch {
            return failed(error, onState)
        }
        orphaned.remove(tier)

        let wanted = artifacts(for: tier)
        let pending = wanted.filter { !exists(destination(for: $0, tier: tier)) }
        guard !pending.isEmpty else { return settle(.installed, onState) }

        let required = pending.reduce(0) { $0 + DiskSpacePolicy.requiredBytes(for: $1) }
        if let failure = diskSpace.check(required, at: layout.models) {
            return failed(failure, onState)
        }

        // Progress is reported across the whole tier, because the row has one bar and a tier is up to two files.
        let totalBytes = wanted.reduce(0) { $0 + $1.byteCount }
        var doneBytes = totalBytes - pending.reduce(0) { $0 + $1.byteCount }
        for artifact in pending {
            let base = doneBytes
            let total = totalBytes
            let received = OSAllocatedUnfairLock<Int64>(initialState: 0)
            let record = readResume(artifact)

            onState(.downloading(DownloadProgress(receivedBytes: base, expectedBytes: total)))
            let outcome: DownloadOutcome
            do {
                outcome = try await downloader.download(
                    artifact, to: layout.staged(artifact), resuming: record?.resumeData
                ) { chunk in
                    // `downloading -> downloading` is a legal transition, so progress needs no guard.
                    received.withLock { $0 = chunk.receivedBytes }
                    onState(
                        .downloading(
                            DownloadProgress(receivedBytes: base + chunk.receivedBytes, expectedBytes: total)))
                }
            } catch {
                return failed(error, onState)
            }

            if case .paused(let resumeData) = outcome {
                let progress = DownloadProgress(
                    receivedBytes: base + received.withLock { $0 }, expectedBytes: total)
                writeResume(
                    ResumeRecord(
                        file: artifact.file,
                        receivedBytes: progress.receivedBytes,
                        expectedBytes: progress.expectedBytes,
                        resumeData: resumeData),
                    for: artifact)
                Self.logger.info("\(artifact.file, privacy: .public) paused at \(progress.receivedBytes) bytes")
                return settle(.paused(progress), onState)
            }
            forgetResume(artifact)

            if let failure = verify(artifact, onState) { return failed(failure, onState) }
            if let failure = await place(artifact, tier: tier, onState) { return failed(failure, onState) }
            doneBytes += artifact.byteCount
        }
        Self.logger.info("\(tier.rawValue, privacy: .public) installed")
        return settle(.installed, onState)
    }

    private func verify(
        _ artifact: ModelArtifact,
        _ onState: @Sendable (ModelInstallState) -> Void
    ) -> ModelInstallFailure? {
        onState(.verifying)
        let staged = layout.staged(artifact)
        let digest: String
        do {
            digest = try ChecksumVerifier.sha256(ofFileAt: staged)
        } catch {
            return .filesystem("\(artifact.file): \(error)")
        }
        guard digest == artifact.sha256 else {
            // The bytes are wrong and there is nothing to resume onto, so they go rather than being kept.
            try? fileManager.removeItem(at: staged)
            Self.logger.error("\(artifact.file, privacy: .public) hashed \(digest, privacy: .public)")
            return .checksumMismatch(expected: artifact.sha256, actual: digest)
        }
        return nil
    }

    /// Moves a verified artefact from staging to where it is used: a rename for weights, unzip-then-rename for
    /// a Core ML encoder.
    private func place(
        _ artifact: ModelArtifact,
        tier: ModelTier,
        _ onState: @Sendable (ModelInstallState) -> Void
    ) async -> ModelInstallFailure? {
        let staged = layout.staged(artifact)
        guard artifact.isArchive else {
            return move(from: staged, to: layout.installed(artifact))
        }
        onState(.extracting)
        if let failure = await unzip(artifact, from: staged) { return failure }
        onState(.compilingCoreML)
        guard let unpacked = unpackedEncoder(for: artifact) else {
            return .filesystem("\(artifact.file): no .mlmodelc in the archive")
        }
        if let failure = move(from: unpacked, to: encoderURL(for: tier)) { return failure }
        try? fileManager.removeItem(at: layout.extraction(artifact))
        try? fileManager.removeItem(at: staged)
        return nil
    }

    private func unzip(_ artifact: ModelArtifact, from staged: URL) async -> ModelInstallFailure? {
        let destination = layout.extraction(artifact)
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return .filesystem(error.localizedDescription)
        }
        do {
            let result = try await launcher.run(
                executable: Self.ditto,
                arguments: [
                    "-x", "-k", staged.path(percentEncoded: false), destination.path(percentEncoded: false),
                ],
                timeout: Self.extractionTimeout)
            guard result.succeeded else {
                Self.logger.error("ditto: \(result.standardError, privacy: .public)")
                return .extraction(result.exitCode)
            }
            return nil
        } catch {
            switch error {
            // ditto's own statuses are positive, so -1 is unambiguously "killed by our watchdog".
            case .timedOut: return .extraction(-1)
            case .launch(let message): return .filesystem("ditto: \(message)")
            }
        }
    }

    /// The `.mlmodelc` directory inside the extraction scratch. Named after the unquantised model upstream, which
    /// is exactly the mismatch `layout.coreMLEncoder(for:)` corrects — but scan as a fallback so an upstream
    /// rename degrades to a slower encode rather than a failed install.
    private func unpackedEncoder(for artifact: ModelArtifact) -> URL? {
        let root = layout.extraction(artifact)
        let expected = root.appending(path: artifact.archiveContentName, directoryHint: .isDirectory)
        if exists(expected) { return expected }
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        guard let found = names.first(where: { $0.hasSuffix(".mlmodelc") }) else { return nil }
        Self.logger.warning(
            "archive unpacked to \(found, privacy: .public), not \(artifact.archiveContentName, privacy: .public)")
        return root.appending(path: found, directoryHint: .isDirectory)
    }

    /// Staging lives under the models directory, so this is a rename on one volume rather than a gigabyte copy.
    private func move(from source: URL, to destination: URL) -> ModelInstallFailure? {
        do {
            if exists(destination) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: source)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
            return nil
        } catch {
            return .filesystem(error.localizedDescription)
        }
    }

    // MARK: Remove

    /// Throws `.inUse` when a `Transcriber` holds this tier: unmapping weights out from under a live context
    /// is a crash, not an error the pipeline can report.
    public func delete(_ tier: ModelTier) throws(ModelInstallFailure) {
        guard !loadedTiers.contains(tier) else {
            Self.logger.error("refused to delete \(tier.rawValue, privacy: .public): loaded")
            throw .inUse
        }
        discard(tier)
        try? fileManager.removeItem(at: weightsURL(for: tier))
        try? fileManager.removeItem(at: encoderURL(for: tier))
        for artifact in catalog.entry(tier).artifacts {
            try? fileManager.removeItem(at: layout.installed(artifact))
        }
        Self.logger.info("deleted \(tier.rawValue, privacy: .public)")
    }

    /// Throws away a paused or interrupted download without touching an installed model.
    /// Deletes every tier, plus anything left in the models directory that the catalogue does not account for.
    ///
    /// `delete(_:)` only removes the files one tier's catalogue entry names, which is right for a single row
    /// but leaves behind whatever an older catalogue, a renamed artefact or a half-finished extraction put
    /// there. Purging is the one place that is allowed to clear the directory itself, so the answer to "why is
    /// there still four gigabytes in Application Support" is never "an orphan nothing knows about".
    ///
    /// The loaded tiers are unloaded first by the caller; this refuses while any is still marked loaded.
    public func purge() throws(ModelInstallFailure) {
        guard loadedTiers.isEmpty else {
            let names = loadedTiers.map(\.rawValue).sorted().joined(separator: ",")
            Self.logger.error("refused to purge: \(names, privacy: .public) is loaded")
            throw .inUse
        }
        for tier in ModelTier.allCases {
            discard(tier)
            try? fileManager.removeItem(at: weightsURL(for: tier))
            try? fileManager.removeItem(at: encoderURL(for: tier))
            for artifact in catalog.entry(tier).artifacts {
                try? fileManager.removeItem(at: layout.installed(artifact))
            }
        }
        let leftovers = (try? fileManager.contentsOfDirectory(atPath: layout.models.path(percentEncoded: false)))
        for name in leftovers ?? [] where name != ModelLayout.stagingDirectoryName {
            try? fileManager.removeItem(at: layout.models.appending(path: name))
        }
        for name in (try? fileManager.contentsOfDirectory(atPath: layout.staging.path(percentEncoded: false))) ?? [] {
            try? fileManager.removeItem(at: layout.staging.appending(path: name))
        }
        clearCoreMLCache()
        Self.logger.info("purged every model")
    }

    /// Removes Core ML's compiled copy of the encoders. It is rebuilt on the next load, so the only cost of
    /// clearing it is that the next Core ML load pays the Neural Engine compile again.
    public func clearCoreMLCache() {
        guard let cache = layout.coreMLCache, exists(cache) else { return }
        do {
            try fileManager.removeItem(at: cache)
            Self.logger.info("cleared the core ml cache")
        } catch {
            Self.logger.error("could not clear the core ml cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func discard(_ tier: ModelTier) {
        for artifact in catalog.entry(tier).artifacts {
            try? fileManager.removeItem(at: layout.staged(artifact))
            forgetResume(artifact)
            try? fileManager.removeItem(at: layout.extraction(artifact))
        }
        orphaned.remove(tier)
    }

    /// Drops an artefact's resume sidecar and the partial file the transport kept for it.
    ///
    /// The sidecar is ours, but the bytes it can resume from are not: the transport keeps them in the system
    /// temp directory, named only inside the resume data. Removing the sidecar alone is exactly how every
    /// cancelled pause used to strand its partial download there.
    private func forgetResume(_ artifact: ModelArtifact) {
        if let resumeData = readResume(artifact)?.resumeData {
            downloader.discardResumeData(resumeData)
        }
        try? fileManager.removeItem(at: layout.resumeSidecar(artifact))
    }

    // MARK: Sidecars

    public func resumeRecord(for tier: ModelTier) -> ResumeRecord? {
        catalog.entry(tier).artifacts.lazy.compactMap { self.readResume($0) }.first
    }

    private func readResume(_ artifact: ModelArtifact) -> ResumeRecord? {
        guard let data = try? Data(contentsOf: layout.resumeSidecar(artifact)) else { return nil }
        return try? JSONDecoder().decode(ResumeRecord.self, from: data)
    }

    private func writeResume(_ record: ResumeRecord, for artifact: ModelArtifact) {
        do {
            try JSONEncoder().encode(record).write(to: layout.resumeSidecar(artifact), options: .atomic)
        } catch {
            // Without the sidecar the next launch reads this as a crash orphan: it restarts rather than resumes.
            Self.logger.error("could not write resume sidecar: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Helpers

    private func destination(for artifact: ModelArtifact, tier: ModelTier) -> URL {
        artifact.isArchive ? encoderURL(for: tier) : layout.installed(artifact)
    }

    private func weightsURL(for tier: ModelTier) -> URL {
        layout.installed(catalog.entry(tier).weights)
    }

    /// The derived path, not the archive's own name. `ModelLayout.coreMLEncoder(for:)` explains why they differ.
    private func encoderURL(for tier: ModelTier) -> URL {
        ModelInstallation.coreMLEncoderURL(for: weightsURL(for: tier))
    }

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func settle(
        _ state: ModelInstallState,
        _ onState: @Sendable (ModelInstallState) -> Void
    ) -> ModelInstallState {
        onState(state)
        return state
    }

    private func failed(
        _ failure: ModelInstallFailure,
        _ onState: @Sendable (ModelInstallState) -> Void
    ) -> ModelInstallState {
        Self.logger.error("install failed: \(failure.code, privacy: .public)")
        return settle(.failed(failure), onState)
    }
}
