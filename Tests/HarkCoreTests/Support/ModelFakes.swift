import Foundation
import HarkCore
import os

/// A `ModelDownloading` that plays a script instead of touching the network.
///
/// Every test in this milestone injects one of these. Nothing in `Tests/` is allowed to make a request, and the
/// catalogue's real artefacts are gigabytes, so the store is always pointed at a fixture table as well.
final class ScriptedDownloader: ModelDownloading {
    enum Script: Sendable {
        /// Land these bytes at the destination, reporting progress on the way.
        case write(Data)
        case fail(ModelInstallFailure)
        /// Report `received` bytes, then answer as a pause would.
        case pause(received: Int64, resumeData: Data?)
    }

    struct Call: Sendable, Equatable {
        let file: String
        let resumeData: Data?
    }

    private let scripts: OSAllocatedUnfairLock<[String: Script]>
    private let recorded = OSAllocatedUnfairLock<[Call]>(initialState: [])
    private let discarded = OSAllocatedUnfairLock<[Data]>(initialState: [])

    /// Every resume blob the store asked this transport to free, in order.
    var discardedResumeData: [Data] { discarded.withLock { $0 } }

    func discardResumeData(_ resumeData: Data) {
        discarded.withLock { $0.append(resumeData) }
    }

    init(_ scripts: [String: Script] = [:]) {
        self.scripts = OSAllocatedUnfairLock(initialState: scripts)
    }

    var calls: [Call] { recorded.withLock { $0 } }
    var files: [String] { calls.map(\.file) }

    func setScript(_ script: Script, for file: String) {
        scripts.withLock { $0[file] = script }
    }

    func download(
        _ artifact: ModelArtifact,
        to destination: URL,
        resuming resumeData: Data?,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws(ModelInstallFailure) -> DownloadOutcome {
        recorded.withLock { $0.append(Call(file: artifact.file, resumeData: resumeData)) }
        let script = scripts.withLock { $0[artifact.file] } ?? .fail(.transport("unscripted \(artifact.file)"))
        progress(DownloadProgress(receivedBytes: 0, expectedBytes: artifact.byteCount))
        switch script {
        case .write(let bytes):
            do {
                try bytes.write(to: destination, options: .atomic)
            } catch {
                throw .filesystem(error.localizedDescription)
            }
            progress(DownloadProgress(receivedBytes: Int64(bytes.count), expectedBytes: artifact.byteCount))
            return .completed
        case .fail(let failure):
            throw failure
        case .pause(let received, let resume):
            progress(DownloadProgress(receivedBytes: received, expectedBytes: artifact.byteCount))
            return .paused(resumeData: resume)
        }
    }
}

/// A `ProcessLaunching` that records what it was asked to run and answers from a canned result.
final class ScriptedLauncher: ProcessLaunching {
    struct Call: Sendable, Equatable {
        let executable: String
        let arguments: [String]
    }

    private let result: Result<ProcessResult, ProcessLaunchFailure>
    private let recorded = OSAllocatedUnfairLock<[Call]>(initialState: [])

    init(_ result: Result<ProcessResult, ProcessLaunchFailure> = .success(ProcessResult(exitCode: 0))) {
        self.result = result
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration?
    ) async throws(ProcessLaunchFailure) -> ProcessResult {
        recorded.withLock {
            $0.append(Call(executable: executable.path(percentEncoded: false), arguments: arguments))
        }
        switch result {
        case .success(let value): return value
        case .failure(let failure): throw failure
        }
    }
}

/// A catalogue of small, locally built artefacts whose hashes are real.
///
/// The published files are between 160 MB and 1.1 GB, so `ModelStoreTests` cannot use `ModelCatalog` and still
/// be a unit test. The shapes are identical: one `.bin` and one `.mlmodelc.zip` per tier.
struct ModelFixtures: Sendable {
    let weightsBytes: Data
    let encoderBytes: Data
    let table: ModelCatalogTable

    /// The name the archive unpacks to, which is deliberately not the name it is installed under.
    static func encoderContentName(for tier: ModelTier) -> String {
        "ggml-\(tier.rawValue)-encoder.mlmodelc"
    }

    static func weightsFile(for tier: ModelTier) -> String { "ggml-\(tier.rawValue)-q8_0.bin" }
    static func encoderFile(for tier: ModelTier) -> String { "\(encoderContentName(for: tier)).zip" }

    /// Builds a real zip with `ditto`, so extraction in the store exercises the real `/usr/bin/ditto` path.
    static func make(in directory: URL, tier: ModelTier = .small, withEncoder: Bool = true) async throws -> Self {
        let weightsBytes = Data((0..<4096).map { UInt8(($0 &* 17 &+ 3) % 256) })
        var encoderBytes = Data()
        if withEncoder {
            let staging = directory.appending(path: "fixture-build", directoryHint: .isDirectory)
            let bundle = staging.appending(path: encoderContentName(for: tier), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("mil".utf8).write(to: bundle.appending(path: "model.mil", directoryHint: .notDirectory))
            try Data("weights".utf8)
                .write(to: bundle.appending(path: "coremldata.bin", directoryHint: .notDirectory))
            let zip = staging.appending(path: "fixture.zip", directoryHint: .notDirectory)
            let result = try await SystemProcessLauncher().run(
                executable: URL(filePath: "/usr/bin/ditto"),
                arguments: [
                    "-c", "-k", "--keepParent", bundle.path(percentEncoded: false),
                    zip.path(percentEncoded: false),
                ],
                timeout: .seconds(30))
            guard result.succeeded else {
                throw FixtureError.ditto(result.exitCode, result.standardError)
            }
            encoderBytes = try Data(contentsOf: zip)
            try FileManager.default.removeItem(at: staging)
        }

        let weights = ModelArtifact(
            file: weightsFile(for: tier),
            url: ModelCatalog.url(forFile: weightsFile(for: tier)),
            byteCount: Int64(weightsBytes.count),
            sha256: ChecksumVerifier.sha256(of: weightsBytes))
        let encoder =
            withEncoder
            ? ModelArtifact(
                file: encoderFile(for: tier),
                url: ModelCatalog.url(forFile: encoderFile(for: tier)),
                byteCount: Int64(encoderBytes.count),
                sha256: ChecksumVerifier.sha256(of: encoderBytes))
            : nil
        let entry = ModelCatalogEntry(
            tier: tier, displayName: "Fixture", weights: weights, coreMLEncoder: encoder)
        // Only `tier` is scripted; asking for another is a test bug rather than a runtime case.
        let table = ModelCatalogTable { requested in
            requested == tier ? entry : ModelCatalog.entry(for: requested)
        }
        return Self(weightsBytes: weightsBytes, encoderBytes: encoderBytes, table: table)
    }

    var entry: ModelCatalogEntry { table.entry(.small) }

    enum FixtureError: Error {
        case ditto(Int32, String)
    }
}

/// A `ModelDownloading` that hangs until its task is cancelled, then answers as a pause would.
///
/// It is how the pause and cancel paths are driven without a timer or a real transfer. The iteration bound is a
/// tripwire, not a timeout: if cancellation never arrives the test fails with a message instead of hanging.
final class PausableDownloader: ModelDownloading {
    let resumeData: Data
    private let entered: AsyncStream<String>
    private let enteredContinuation: AsyncStream<String>.Continuation
    private let recorded = OSAllocatedUnfairLock<[String]>(initialState: [])

    init(resumeData: Data = Data("resume blob".utf8)) {
        self.resumeData = resumeData
        (entered, enteredContinuation) = AsyncStream.makeStream()
    }

    var files: [String] { recorded.withLock { $0 } }

    /// Returns once `download` has been entered at least once. The stream buffers, so calling this after the
    /// fact still resolves.
    func waitUntilStarted() async {
        for await _ in entered { return }
    }

    func download(
        _ artifact: ModelArtifact,
        to destination: URL,
        resuming resumeData: Data?,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws(ModelInstallFailure) -> DownloadOutcome {
        recorded.withLock { $0.append(artifact.file) }
        enteredContinuation.yield(artifact.file)
        progress(DownloadProgress(receivedBytes: 64, expectedBytes: artifact.byteCount))
        for _ in 0..<5_000 {
            if Task.isCancelled { return .paused(resumeData: self.resumeData) }
            try? await Task.sleep(for: .milliseconds(1))
        }
        throw .transport("cancellation never arrived")
    }
}

enum DeadlineError: Error, Equatable {
    case expired
}

/// Runs `body` against a wall-clock bound. Every async test in the model slice goes through it, so a regression
/// in cancellation or stream delivery is a red test rather than a stuck run.
func withDeadline<T: Sendable>(
    _ seconds: Double = 5,
    _ body: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let value = first else { throw DeadlineError.expired }
        return value
    }
}
