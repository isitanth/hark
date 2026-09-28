import Foundation
import HarkCore
import Testing
import os

@Suite struct ModelStoreTests {
    private let fileManager = FileManager.default

    private func layout(_ directory: TemporaryDirectory) -> ModelLayout {
        ModelLayout(models: directory.url.appending(path: "models", directoryHint: .isDirectory))
    }

    private func makeStore(
        _ directory: TemporaryDirectory,
        _ fixtures: ModelFixtures,
        _ downloader: ScriptedDownloader,
        launcher: any ProcessLaunching = SystemProcessLauncher(),
        space: Int64 = .max
    ) -> ModelStore {
        ModelStore(
            layout: layout(directory),
            downloader: downloader,
            launcher: launcher,
            diskSpace: DiskSpacePolicy { _ in space },
            catalog: fixtures.table)
    }

    private func scripted(_ fixtures: ModelFixtures) -> ScriptedDownloader {
        var scripts: [String: ScriptedDownloader.Script] = [
            fixtures.entry.weights.file: .write(fixtures.weightsBytes)
        ]
        if let encoder = fixtures.entry.coreMLEncoder {
            scripts[encoder.file] = .write(fixtures.encoderBytes)
        }
        return ScriptedDownloader(scripts)
    }

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Collapses the repeated `downloading` ticks, so the assertion is about the shape of the run.
    private func phases(_ states: [ModelInstallState]) -> [ModelInstallState.Phase] {
        states.map(\.phase).reduce(into: []) { result, phase in
            if result.last != phase { result.append(phase) }
        }
    }

    // MARK: Install

    @Test func aTierInstallsAndEveryTransitionItEmitsIsLegal() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let downloader = scripted(fixtures)
        let store = makeStore(directory, fixtures, downloader)
        let seen = OSAllocatedUnfairLock<[ModelInstallState]>(initialState: [])

        let final = await store.install(.small) { state in seen.withLock { $0.append(state) } }

        #expect(final == .installed)
        let states = seen.withLock { $0 }
        #expect(
            phases(states) == [
                .downloading, .verifying, .downloading, .verifying, .extracting, .compilingCoreML, .installed,
            ])
        for (from, to) in zip(states, states.dropFirst()) {
            #expect(from.canTransition(to: to), "\(from.phase) -> \(to.phase) is not a legal transition")
        }
    }

    /// The encoder has to end up exactly where whisper.cpp will look, which is the unquantised name — the same
    /// one the archive already unpacks under. This asserts the installed path rather than the absence of a
    /// rename, so it stays honest whichever way the archive is published.
    ///
    /// It is worth its own test because getting it wrong is silent: the weights still load, just on Metal
    /// alone, and only whisper's own "failed to load Core ML model" line says so. That is exactly what shipped
    /// for a while, when this asserted the quantised name instead and the install renamed the directory to match.
    @Test func theEncoderIsInstalledWhereWhisperWillLookForIt() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let store = makeStore(directory, fixtures, scripted(fixtures))

        #expect(await store.install(.small) { _ in } == .installed)

        let models = layout(directory).models
        let weights = models.appending(path: "ggml-small-q8_0.bin", directoryHint: .notDirectory)
        let derived = ModelInstallation.coreMLEncoderURL(for: weights)
        #expect(derived.lastPathComponent == "ggml-small-encoder.mlmodelc")
        #expect(exists(derived))
        #expect(exists(derived.appending(path: "model.mil", directoryHint: .notDirectory)))
        // Nothing left behind under any other spelling.
        let quantised = models.appending(path: "ggml-small-q8_0-encoder.mlmodelc", directoryHint: .isDirectory)
        #expect(!exists(quantised))

        let installation = try #require(await store.installation(for: .small))
        #expect(installation.weights == weights)
        #expect(installation.coreMLEncoder == derived)
    }

    @Test func stagingIsEmptyAndTheZipIsGoneOnceTheInstallLands() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let store = makeStore(directory, fixtures, scripted(fixtures))

        #expect(await store.install(.small) { _ in } == .installed)

        let staging = layout(directory).staging.path(percentEncoded: false)
        #expect(try fileManager.contentsOfDirectory(atPath: staging).isEmpty)
    }

    @Test func anArtefactAlreadyInPlaceIsNotFetchedTwice() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let downloader = scripted(fixtures)
        let store = makeStore(directory, fixtures, downloader)

        #expect(await store.install(.small) { _ in } == .installed)
        let afterFirst = downloader.files
        #expect(await store.install(.small) { _ in } == .installed)

        #expect(downloader.files == afterFirst)
        #expect(afterFirst.count == 2)
    }

    @Test func theModelsDirectoryIsExcludedFromBackup() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let store = makeStore(directory, fixtures, scripted(fixtures))

        try await store.prepare()

        let values = try layout(directory).models.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    // MARK: Purge

    @Test func purgeEmptiesTheDirectory() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let store = makeStore(directory, fixtures, scripted(fixtures))
        #expect(await store.install(.small) { _ in } == .installed)
        #expect(exists(layout(directory).weights(for: .small)))

        // An orphan no catalogue entry names: the reason purge clears the directory rather than a file list.
        let stray = layout(directory).models.appending(path: "ggml-from-an-older-build.bin")
        try Data("stray".utf8).write(to: stray)

        try await store.purge()

        #expect(!exists(layout(directory).weights(for: .small)))
        #expect(!exists(layout(directory).coreMLEncoder(for: .small)))
        #expect(!exists(stray))
        // The directory itself survives, so the next download has somewhere to go.
        #expect(exists(layout(directory).models))
        let staging = layout(directory).staging.path(percentEncoded: false)
        #expect(try fileManager.contentsOfDirectory(atPath: staging).isEmpty)
        #expect(await store.launchState(for: .small) == .notInstalled)
    }

    @Test func purgeRefusesWhileAModelIsLoaded() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let store = makeStore(directory, fixtures, scripted(fixtures))
        #expect(await store.install(.small) { _ in } == .installed)
        await store.setLoaded([.small])

        await #expect(throws: ModelInstallFailure.inUse) { try await store.purge() }
        #expect(exists(layout(directory).weights(for: .small)))

        await store.setLoaded([])
        try await store.purge()
        #expect(!exists(layout(directory).weights(for: .small)))
    }

    // MARK: Leftovers outside the models folder

    /// The partial a paused download keeps lives with the transport, not in staging. Cancelling used to delete
    /// the sidecar and strand those bytes in the system temp directory; the transport now gets told to free them.
    @Test func cancellingAPauseFreesThePartialTheTransportKept() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let downloader = scripted(fixtures)
        let blob = Data("resume-me".utf8)
        downloader.setScript(.pause(received: 100, resumeData: blob), for: fixtures.entry.weights.file)
        let store = makeStore(directory, fixtures, downloader)

        _ = await store.install(.small) { _ in }
        #expect(await store.resumeRecord(for: .small)?.resumeData == blob)

        await store.discard(.small)

        #expect(downloader.discardedResumeData == [blob])
        #expect(await store.resumeRecord(for: .small) == nil)
    }

    @Test func purgeFreesPausedPartialsAndTheCoreMLCache() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url, withEncoder: false)
        let downloader = scripted(fixtures)
        let blob = Data("resume-me".utf8)
        downloader.setScript(.pause(received: 100, resumeData: blob), for: fixtures.entry.weights.file)
        let cache = directory.url.appending(path: "Caches/com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: cache.appending(path: "bundle"))
        let layout = ModelLayout(models: layout(directory).models, coreMLCache: cache)
        let store = ModelStore(
            layout: layout, downloader: downloader, launcher: SystemProcessLauncher(),
            diskSpace: DiskSpacePolicy { _ in .max }, catalog: fixtures.table)

        _ = await store.install(.small) { _ in }
        try await store.purge()

        #expect(downloader.discardedResumeData == [blob])
        #expect(!exists(cache), "Core ML's compiled encoders survived the purge")
    }

    // MARK: The Core ML toggle

    @Test func withCoreMLOffATierIsItsWeightsAlone() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let downloader = scripted(fixtures)
        let store = ModelStore(
            layout: layout(directory), downloader: downloader, launcher: SystemProcessLauncher(),
            diskSpace: DiskSpacePolicy { _ in .max }, catalog: fixtures.table, coreMLEnabled: false)

        #expect(await store.install(.small) { _ in } == .installed)

        #expect(downloader.files == [fixtures.entry.weights.file], "the encoder was fetched with Core ML off")
        #expect(!exists(layout(directory).coreMLEncoder(for: .small)))
        #expect(await store.isInstalled(.small))
    }

    @Test func turningCoreMLOffRemovesTheEncoderAndKeepsTheWeights() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let store = makeStore(directory, fixtures, scripted(fixtures))
        #expect(await store.install(.small) { _ in } == .installed)
        #expect(exists(layout(directory).coreMLEncoder(for: .small)))

        await store.setCoreMLEnabled(false)

        #expect(!exists(layout(directory).coreMLEncoder(for: .small)))
        #expect(exists(layout(directory).weights(for: .small)))
        #expect(await store.isInstalled(.small), "weights alone should still count as installed with Core ML off")
        #expect(await store.installation(for: .small)?.coreMLEncoder == nil)
    }

    /// Turning it back on makes the missing encoder the only thing a reinstall fetches.
    @Test func turningCoreMLOnFetchesOnlyTheMissingEncoder() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let downloader = scripted(fixtures)
        let store = ModelStore(
            layout: layout(directory), downloader: downloader, launcher: SystemProcessLauncher(),
            diskSpace: DiskSpacePolicy { _ in .max }, catalog: fixtures.table, coreMLEnabled: false)
        #expect(await store.install(.small) { _ in } == .installed)

        await store.setCoreMLEnabled(true)
        #expect(await store.isInstalled(.small) == false)
        #expect(await store.install(.small) { _ in } == .installed)

        let encoder = try #require(fixtures.entry.coreMLEncoder)
        #expect(downloader.files == [fixtures.entry.weights.file, encoder.file])
        #expect(exists(layout(directory).coreMLEncoder(for: .small)))
    }

    // MARK: Refusals

    @Test func aBadHashFailsAndTakesTheStagedBytesWithIt() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let downloader = scripted(fixtures)
        downloader.setScript(.write(Data("not the weights".utf8)), for: fixtures.entry.weights.file)
        let store = makeStore(directory, fixtures, downloader)

        let final = await store.install(.small) { _ in }

        let expected = fixtures.entry.weights.sha256
        let actual = ChecksumVerifier.sha256(of: Data("not the weights".utf8))
        #expect(final == .failed(.checksumMismatch(expected: expected, actual: actual)))
        #expect(!exists(layout(directory).staged(fixtures.entry.weights)))
        #expect(!exists(layout(directory).installed(fixtures.entry.weights)))
    }

    @Test func noRoomMeansTheDownloaderIsNeverCalled() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let downloader = scripted(fixtures)
        let store = makeStore(directory, fixtures, downloader, space: 0)

        let final = await store.install(.small) { _ in }

        #expect(final.failure?.code.hasPrefix("insufficient_space") == true)
        #expect(downloader.calls.isEmpty)
    }

    @Test func aTransportFailureSurfacesAsFailed() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let downloader = scripted(fixtures)
        downloader.setScript(.fail(.http(403)), for: fixtures.entry.weights.file)
        let store = makeStore(directory, fixtures, downloader)

        #expect(await store.install(.small) { _ in } == .failed(.http(403)))
    }

    @Test func anExtractionFailureCarriesDittosExitCode() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let launcher = ScriptedLauncher(.success(ProcessResult(exitCode: 2, standardError: "bad zip")))
        let store = makeStore(directory, fixtures, scripted(fixtures), launcher: launcher)

        #expect(await store.install(.small) { _ in } == .failed(.extraction(2)))
    }

    @Test func dittoIsAskedToExtractTheStagedArchiveIntoItsOwnScratch() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let launcher = ScriptedLauncher()
        let store = makeStore(directory, fixtures, scripted(fixtures), launcher: launcher)

        // A launcher that reports success without unpacking anything, so the install stops at the missing bundle.
        #expect(await store.install(.small) { _ in } != .installed)

        let encoder = try #require(fixtures.entry.coreMLEncoder)
        #expect(
            launcher.calls == [
                ScriptedLauncher.Call(
                    executable: "/usr/bin/ditto",
                    arguments: [
                        "-x", "-k",
                        layout(directory).staged(encoder).path(percentEncoded: false),
                        layout(directory).extraction(encoder).path(percentEncoded: false),
                    ])
            ])
    }

    // MARK: Pause, resume, relaunch

    @Test func aPauseWritesTheSidecarAndTheNextLaunchReadsPausedWithoutTouchingTheNetwork() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let downloader = scripted(fixtures)
        let resume = Data("opaque resume blob".utf8)
        downloader.setScript(.pause(received: 1_024, resumeData: resume), for: fixtures.entry.weights.file)
        let store = makeStore(directory, fixtures, downloader)

        let final = await store.install(.small) { _ in }
        let expected = DownloadProgress(receivedBytes: 1_024, expectedBytes: fixtures.entry.downloadByteCount)
        #expect(final == .paused(expected))
        #expect(exists(layout(directory).resumeSidecar(fixtures.entry.weights)))

        // A second store over the same directory is the relaunch. It reads Paused, and never resumes on its own.
        let relaunched = ScriptedDownloader()
        let next = makeStore(directory, fixtures, relaunched)
        try await next.prepare()
        #expect(await next.launchState(for: .small) == .paused(expected))
        #expect(relaunched.calls.isEmpty)
    }

    @Test func resumeDataGoesBackToTheDownloaderOnTheNextStart() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let downloader = scripted(fixtures)
        let resume = Data("opaque resume blob".utf8)
        downloader.setScript(.pause(received: 512, resumeData: resume), for: fixtures.entry.weights.file)
        let store = makeStore(directory, fixtures, downloader)
        #expect(
            await store.install(.small) { _ in }
                == .paused(
                    DownloadProgress(receivedBytes: 512, expectedBytes: fixtures.entry.downloadByteCount)))

        downloader.setScript(.write(fixtures.weightsBytes), for: fixtures.entry.weights.file)
        #expect(await store.install(.small) { _ in } == .installed)

        #expect(downloader.calls.map(\.resumeData) == [nil, resume, nil])
        #expect(!exists(layout(directory).resumeSidecar(fixtures.entry.weights)))
    }

    @Test func aStagedFileWithNoSidecarIsSweptAndTheRowReadsInterrupted() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let staged = layout(directory).staged(fixtures.entry.weights)
        try fileManager.createDirectory(at: layout(directory).staging, withIntermediateDirectories: true)
        try Data("half a download".utf8).write(to: staged)

        let store = makeStore(directory, fixtures, ScriptedDownloader())
        try await store.prepare()

        #expect(!exists(staged))
        #expect(await store.launchState(for: .small) == .interrupted)
    }

    @Test func aStagedFileWithASidecarIsAPauseAndSurvivesTheSweep() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let artifact = fixtures.entry.weights
        try fileManager.createDirectory(at: layout(directory).staging, withIntermediateDirectories: true)
        let staged = layout(directory).staged(artifact)
        try Data("half a download".utf8).write(to: staged)
        let record = ResumeRecord(file: artifact.file, receivedBytes: 15, expectedBytes: 200, resumeData: nil)
        try JSONEncoder().encode(record).write(to: layout(directory).resumeSidecar(artifact))

        let store = makeStore(directory, fixtures, ScriptedDownloader())
        try await store.prepare()

        #expect(exists(staged))
        #expect(await store.launchState(for: .small) == .paused(record.progress))
    }

    @Test func anEmptyDirectoryIsNotInstalledRatherThanInterrupted() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let store = makeStore(directory, fixtures, ScriptedDownloader())
        try await store.prepare()
        #expect(await store.launchState(for: .small) == .notInstalled)
    }

    @Test func discardClearsAPausedDownloadAndLeavesNothingBehind() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let downloader = scripted(fixtures)
        downloader.setScript(.pause(received: 8, resumeData: Data("r".utf8)), for: fixtures.entry.weights.file)
        let store = makeStore(directory, fixtures, downloader)
        _ = await store.install(.small) { _ in }

        await store.discard(.small)

        #expect(await store.launchState(for: .small) == .notInstalled)
        #expect(!exists(layout(directory).resumeSidecar(fixtures.entry.weights)))
    }

    // MARK: Delete

    @Test func deleteIsRefusedWhileTheTranscriberHoldsTheTier() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let store = makeStore(directory, fixtures, scripted(fixtures))
        #expect(await store.install(.small) { _ in } == .installed)
        await store.setLoaded([.small])

        await #expect(throws: ModelInstallFailure.inUse) { try await store.delete(.small) }
        #expect(await store.isInstalled(.small))

        await store.setLoaded([])
        try await store.delete(.small)
        #expect(await store.isInstalled(.small) == false)
        #expect(await store.installation(for: .small) == nil)
        #expect(!exists(layout(directory).models.appending(path: "ggml-small-q8_0-encoder.mlmodelc")))
    }

    @Test func anotherTierBeingLoadedDoesNotBlockThisDelete() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let store = makeStore(directory, fixtures, scripted(fixtures))
        #expect(await store.install(.small) { _ in } == .installed)
        await store.setLoaded([.large])

        try await store.delete(.small)
        #expect(await store.isInstalled(.small) == false)
    }

    /// The final on Large and the live text on Small: Small is held even though it is not the final's tier.
    @Test func everyTierInTheLoadedSetIsRefused() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let store = makeStore(directory, fixtures, scripted(fixtures))
        #expect(await store.install(.small) { _ in } == .installed)
        await store.setLoaded([.large, .small])

        await #expect(throws: ModelInstallFailure.inUse) { try await store.delete(.small) }
        #expect(await store.isInstalled(.small))

        await store.setLoaded([.large])
        try await store.delete(.small)
        #expect(await store.isInstalled(.small) == false)
    }

    @Test func purgeRefusesWhileAnyTierIsLoaded() async throws {
        let directory = try TemporaryDirectory()
        let fixtures = try await ModelFixtures.make(in: directory.url)
        let store = makeStore(directory, fixtures, scripted(fixtures))
        #expect(await store.install(.small) { _ in } == .installed)
        await store.setLoaded([.large])

        await #expect(throws: ModelInstallFailure.inUse) { try await store.purge() }
        #expect(exists(layout(directory).weights(for: .small)))
        #expect(await store.loaded == [.large])

        await store.setLoaded([])
        try await store.purge()
        #expect(!exists(layout(directory).weights(for: .small)))
    }
}
