import Foundation
import HarkCore
import Testing

@Suite struct DownloadCoordinatorTests {
    private let fileManager = FileManager.default

    private func layout(_ directory: TemporaryDirectory) -> ModelLayout {
        ModelLayout(models: directory.url.appending(path: "models", directoryHint: .isDirectory))
    }

    private func makeCoordinator(
        _ directory: TemporaryDirectory,
        _ fixtures: ModelFixtures,
        _ downloader: any ModelDownloading
    ) -> DownloadCoordinator {
        DownloadCoordinator(
            store: ModelStore(
                layout: layout(directory),
                downloader: downloader,
                diskSpace: DiskSpacePolicy { _ in .max },
                catalog: fixtures.table))
    }

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Plants a paused download for `.small`: staged bytes plus the sidecar that makes them a pause rather than
    /// a crash orphan.
    @discardableResult
    private func plantResume(_ directory: TemporaryDirectory, _ fixtures: ModelFixtures) throws -> ResumeRecord {
        let artifact = fixtures.entry.weights
        try fileManager.createDirectory(at: layout(directory).staging, withIntermediateDirectories: true)
        try Data("half a download".utf8).write(to: layout(directory).staged(artifact))
        let record = ResumeRecord(
            file: artifact.file,
            receivedBytes: 15,
            expectedBytes: fixtures.entry.downloadByteCount,
            resumeData: Data("opaque resume blob".utf8))
        try JSONEncoder().encode(record).write(to: layout(directory).resumeSidecar(artifact))
        return record
    }

    /// Consumes `updates()` until `tier` reaches a state satisfying `predicate`, under a wall-clock bound.
    ///
    /// The stream opens with every tier's current state, so subscribing after the state has already been reached
    /// still resolves — there is no lost wake-up to race against and no unbounded wait.
    private func awaitState(
        _ coordinator: DownloadCoordinator,
        _ tier: ModelTier,
        _ predicate: @escaping @Sendable (ModelInstallState) -> Bool
    ) async throws -> ModelInstallState {
        let stream = await coordinator.updates()
        return try await withDeadline {
            for await update in stream where update.tier == tier && predicate(update.state) {
                return update.state
            }
            return .notInstalled
        }
    }

    // MARK: Init starts nothing

    @Test func initCallsTheDownloaderZeroTimesEvenWithAResumeFileWaiting() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        try plantResume(directory, fixtures)
        let downloader = ScriptedDownloader()

        let coordinator = makeCoordinator(directory, fixtures, downloader)

        // The round trip is what makes this an assertion rather than a coincidence of timing: anything `init`
        // had enqueued on the actor would have run before `snapshot` answers.
        #expect(await coordinator.snapshot() == [.small: .notInstalled, .medium: .notInstalled, .large: .notInstalled])
        #expect(downloader.calls.isEmpty)
    }

    @Test func initDoesNotEvenCreateTheModelsDirectory() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let downloader = ScriptedDownloader()

        let coordinator = makeCoordinator(directory, fixtures, downloader)

        #expect(await coordinator.state(for: .small) == .notInstalled)
        #expect(!exists(layout(directory).models))
        #expect(downloader.calls.isEmpty)
    }

    @Test func refreshReadsTheSidecarAsPausedAndStillNeverDownloads() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let record = try plantResume(directory, fixtures)
        let downloader = ScriptedDownloader()
        let coordinator = makeCoordinator(directory, fixtures, downloader)

        await coordinator.refresh()

        #expect(await coordinator.state(for: .small) == .paused(record.progress))
        #expect(downloader.calls.isEmpty)
    }

    @Test func refreshReadsAnOrphanedPartialAsInterruptedRatherThanDownloading() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        try fileManager.createDirectory(at: layout(directory).staging, withIntermediateDirectories: true)
        try Data("half a download".utf8).write(to: layout(directory).staged(fixtures.entry.weights))
        let downloader = ScriptedDownloader()
        let coordinator = makeCoordinator(directory, fixtures, downloader)

        await coordinator.refresh()

        #expect(await coordinator.state(for: .small) == .interrupted)
        #expect(downloader.calls.isEmpty)
    }

    // MARK: Streaming

    @Test func aLateSubscriberOpensOnTheCurrentStateOfEveryTier() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let downloader = ScriptedDownloader([fixtures.entry.weights.file: .write(fixtures.weightsBytes)])
        let coordinator = makeCoordinator(directory, fixtures, downloader)
        await coordinator.refresh()
        await coordinator.start(.small)
        _ = try await awaitState(coordinator, .small) { $0 == .installed }

        let stream = await coordinator.updates()
        let opening = try await withDeadline { () -> [ModelTier: ModelInstallState] in
            var seen: [ModelTier: ModelInstallState] = [:]
            for await update in stream {
                seen[update.tier] = update.state
                if seen.count == ModelTier.allCases.count { break }
            }
            return seen
        }

        #expect(opening == [.small: .installed, .medium: .notInstalled, .large: .notInstalled])
    }

    @Test func startRunsTheInstallAndTheStreamCarriesItToInstalled() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let downloader = ScriptedDownloader([fixtures.entry.weights.file: .write(fixtures.weightsBytes)])
        let coordinator = makeCoordinator(directory, fixtures, downloader)
        await coordinator.refresh()

        await coordinator.start(.small)

        #expect(try await awaitState(coordinator, .small) { $0 == .installed } == .installed)
        #expect(downloader.files == [fixtures.entry.weights.file])
        #expect(exists(layout(directory).weights(for: .small)))
    }

    @Test func aFailedInstallLeavesTheRowOnFailedAndTheTierStartableAgain() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let downloader = ScriptedDownloader([fixtures.entry.weights.file: .fail(.transport("offline"))])
        let coordinator = makeCoordinator(directory, fixtures, downloader)
        await coordinator.refresh()

        await coordinator.start(.small)

        let state = try await awaitState(coordinator, .small) { $0.phase == .failed }
        #expect(state == .failed(.transport("offline")))
        #expect(state.canStart)
    }

    // MARK: Pause and cancel

    @Test func pauseStopsTheRunAndTheRelaunchedRowReadsPausedWithoutResuming() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let downloader = PausableDownloader()
        let coordinator = makeCoordinator(directory, fixtures, downloader)
        await coordinator.refresh()

        await coordinator.start(.small)
        try await withDeadline { await downloader.waitUntilStarted() }
        await coordinator.pause(.small)

        let paused = try await awaitState(coordinator, .small) { $0.phase == .paused }
        #expect(paused == .paused(DownloadProgress(receivedBytes: 64, expectedBytes: 4_096)))
        #expect(exists(layout(directory).resumeSidecar(fixtures.entry.weights)))

        // A second coordinator over the same directory is the relaunch. It reads Paused off the disk and leaves
        // the downloader alone until something clicks Resume.
        let relaunched = ScriptedDownloader()
        let next = makeCoordinator(directory, fixtures, relaunched)
        await next.refresh()
        #expect(await next.state(for: .small).phase == .paused)
        #expect(relaunched.calls.isEmpty)
    }

    @Test func resumeDataFromThePauseGoesBackToTheDownloaderOnTheNextStart() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let downloader = PausableDownloader()
        let coordinator = makeCoordinator(directory, fixtures, downloader)
        await coordinator.refresh()
        await coordinator.start(.small)
        try await withDeadline { await downloader.waitUntilStarted() }
        await coordinator.pause(.small)
        _ = try await awaitState(coordinator, .small) { $0.phase == .paused }

        let resumed = ScriptedDownloader([fixtures.entry.weights.file: .write(fixtures.weightsBytes)])
        let next = makeCoordinator(directory, fixtures, resumed)
        await next.refresh()
        await next.start(.small)

        #expect(try await awaitState(next, .small) { $0 == .installed } == .installed)
        #expect(resumed.calls.map(\.resumeData) == [downloader.resumeData])
    }

    @Test func cancelThrowsAwayThePartialAndTheRowReadsNotInstalled() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let downloader = PausableDownloader()
        let coordinator = makeCoordinator(directory, fixtures, downloader)
        await coordinator.refresh()
        await coordinator.start(.small)
        try await withDeadline { await downloader.waitUntilStarted() }

        await coordinator.cancel(.small)

        #expect(await coordinator.state(for: .small) == .notInstalled)
        #expect(!exists(layout(directory).resumeSidecar(fixtures.entry.weights)))
        #expect(!exists(layout(directory).staged(fixtures.entry.weights)))
    }

    @Test func asecondStartIsIgnoredWhileTheTierIsAlreadyRunning() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let downloader = PausableDownloader()
        let coordinator = makeCoordinator(directory, fixtures, downloader)
        await coordinator.refresh()
        await coordinator.start(.small)
        try await withDeadline { await downloader.waitUntilStarted() }

        await coordinator.start(.small)
        await coordinator.cancel(.small)

        #expect(downloader.files == [fixtures.entry.weights.file])
    }

    // MARK: Delete

    @Test func deleteIsRefusedWhileTheTierIsLoadedAndTheRowStaysInstalled() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let downloader = ScriptedDownloader([fixtures.entry.weights.file: .write(fixtures.weightsBytes)])
        let coordinator = makeCoordinator(directory, fixtures, downloader)
        await coordinator.refresh()
        await coordinator.start(.small)
        _ = try await awaitState(coordinator, .small) { $0 == .installed }

        await coordinator.setLoaded([.small])
        #expect(await coordinator.delete(.small) == .inUse)
        #expect(await coordinator.state(for: .small) == .installed)
        #expect(exists(layout(directory).weights(for: .small)))

        await coordinator.setLoaded([])
        #expect(await coordinator.delete(.small) == nil)
        #expect(await coordinator.state(for: .small) == .notInstalled)
        #expect(!exists(layout(directory).weights(for: .small)))
    }
}
