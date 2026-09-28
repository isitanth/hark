import Foundation
import HarkCore
import Testing
import os

/// The only tests that hit the network and the real models directory.
///
/// Everything else injects a downloader and a temp directory, which proves the logic and nothing about the
/// live service. These prove the other half: that the pinned URLs still resolve, that the bytes still hash to
/// what the catalogue says, and that what lands on disk is what whisper.cpp will look for.
///
///     HARK_TEST_INSTALL=small swift test --filter ModelInstallIntegrationTests
///
/// It installs into `~/Library/Application Support/Hark/models`, the same place the app uses, on purpose: a
/// copy in a temp directory would not tell us the app can load it afterwards.
enum InstallTarget {
    static let tier = ProcessInfo.processInfo.environment["HARK_TEST_INSTALL"]
        .flatMap(ModelTier.init(rawValue:))
}

@Suite(.enabled(if: InstallTarget.tier != nil), .serialized)
struct ModelInstallIntegrationTests {
    private let paths = AppPaths.standard()
    private let fileManager = FileManager.default

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func theModelInstallsWhereTheAppWillFindIt() async throws {
        let tier = try #require(InstallTarget.tier)
        let layout = ModelLayout(paths: paths)
        let store = ModelStore(layout: layout, downloader: .standard)
        try await store.prepare()

        // The progress closure is called from the store's own task, so the phases it reports need a lock.
        let phases = OSAllocatedUnfairLock(initialState: [ModelInstallState.Phase]())
        let state = await store.install(tier) { update in
            phases.withLock { if $0.last != update.phase { $0.append(update.phase) } }
        }
        #expect(state == .installed, "install ended as \(state)")
        let seen = phases.withLock { $0 }

        // The phases the Model tab renders, in the order it renders them.
        #expect(seen.contains(.downloading))
        #expect(seen.contains(.verifying))
        #expect(seen.last == .installed)

        let entry = ModelCatalog.entry(for: tier)
        let weights = layout.weights(for: tier)
        #expect(exists(weights))

        let size = try fileManager.attributesOfItem(atPath: weights.path(percentEncoded: false))[.size] as? Int64
        #expect(size == entry.weights.byteCount, "size on disk does not match the catalogue")
        #expect(try ChecksumVerifier.verify(fileAt: weights, matches: entry.weights.sha256))

        // The path whisper.cpp derives, which is the whole point of the encoder being installed at all.
        if entry.coreMLEncoder != nil {
            let encoder = ModelInstallation.coreMLEncoderURL(for: weights)
            #expect(exists(encoder), "no encoder at \(encoder.lastPathComponent); Core ML would be skipped")
            #expect(exists(encoder.appending(path: "model.mil", directoryHint: .notDirectory)))
        }

        // Nothing left over: no staged bytes, no zip, no extraction scratch.
        let staging = try fileManager.contentsOfDirectory(atPath: layout.staging.path(percentEncoded: false))
        #expect(staging.isEmpty, "staging still holds \(staging)")

        let installation = try #require(await store.installation(for: tier))
        #expect(installation.weights == weights)
    }

    /// Reports what the app would show for the tier at launch, without touching the network. Run it after
    /// killing an install to check that a half-written file reads as interrupted rather than as a download
    /// still in progress, or as nothing at all.
    ///
    ///     HARK_TEST_INSTALL=small HARK_TEST_STATE=1 swift test --filter ModelInstallIntegrationTests
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARK_TEST_STATE"] != nil))
    func theLaunchStateAfterAKillIsInterrupted() async throws {
        let tier = try #require(InstallTarget.tier)
        let layout = ModelLayout(paths: paths)
        let store = ModelStore(layout: layout, downloader: .standard)

        // Before prepare: the raw reading, with the orphan still on disk.
        let staged = try? fileManager.contentsOfDirectory(atPath: layout.staging.path(percentEncoded: false))
        try await store.prepare()
        let state = await store.launchState(for: tier)

        try ("staged before prepare: \(staged ?? [])\nlaunch state: \(state)\n").write(
            to: URL(filePath: "/tmp/hark-state-result.txt"), atomically: true, encoding: .utf8)

        #expect(state == .interrupted, "a killed download should read interrupted, got \(state)")
        // The sweep removed the orphan, so a second launch is not still interrupted by the same bytes.
        let after = try fileManager.contentsOfDirectory(atPath: layout.staging.path(percentEncoded: false))
        #expect(after.isEmpty, "staging still holds \(after)")
    }

    /// A second install is a no-op rather than a second download. Cheap to check and it is what makes a
    /// relaunch after a completed install free.
    @Test func installingTwiceDoesNotFetchAgain() async throws {
        let tier = try #require(InstallTarget.tier)
        let store = ModelStore(layout: ModelLayout(paths: paths), downloader: .standard)
        try await store.prepare()

        let started = ContinuousClock.now
        #expect(await store.install(tier) { _ in } == .installed)
        let elapsed = started.duration(to: .now)

        #expect(elapsed < .seconds(10), "a no-op install took \(elapsed); it re-downloaded")
    }

    /// The end-to-end version of the question "does purge leave anything behind", with a real transport.
    ///
    /// A real download is paused, which makes URLSession keep a genuine partial in the system temp directory —
    /// the leftover that every cancelled pause used to strand. Then purge runs, and the partial has to be gone.
    /// It uses a temporary models folder, so the installed models are not touched.
    ///
    ///     HARK_TEST_INSTALL=small HARK_TEST_PURGE=1 swift test --filter ModelInstallIntegrationTests
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARK_TEST_PURGE"] != nil))
    func purgeFreesARealPausedPartialFromTheSystemTempDirectory() async throws {
        let tier = try #require(InstallTarget.tier)
        let directory = try TemporaryDirectory()
        let layout = ModelLayout(models: directory.url.appending(path: "models", directoryHint: .isDirectory))
        let store = ModelStore(layout: layout, downloader: .standard, coreMLEnabled: false)
        try await store.prepare()

        let run = Task { await store.install(tier) { _ in } }
        try await Task.sleep(for: .seconds(3))
        run.cancel()
        let outcome = await run.value
        guard case .paused = outcome else {
            Issue.record("expected a pause, got \(outcome); the download may have finished inside 3 s")
            return
        }

        let resumeData = try #require(await store.resumeRecord(for: tier)?.resumeData)
        let name = try #require(URLSessionDownloader.temporaryFileName(in: resumeData))
        let partial = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .notDirectory)
        let size =
            (try? FileManager.default.attributesOfItem(atPath: partial.path(percentEncoded: false))[.size])
            as? Int64
        #expect(exists(partial), "the pause left no partial to free, so this proves nothing")

        try await store.purge()

        #expect(!exists(partial), "\(name) (\(size ?? 0) bytes) survived the purge in the system temp directory")
        #expect(await store.resumeRecord(for: tier) == nil)
    }
}
