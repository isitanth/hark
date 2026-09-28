import Foundation

/// Where every file a model install touches lives. Pure path arithmetic, so it is testable without a disk.
///
/// Staging sits *inside* the models directory rather than beside it so that the move into place is a rename on
/// one volume. A cross-volume move would copy a gigabyte and stop being atomic.
public struct ModelLayout: Sendable, Equatable {
    /// Marks the JSON sidecar that makes a staged artefact a pause rather than a crash orphan.
    public static let resumeSuffix = ".resume"
    public static let stagingDirectoryName = ".staging"

    public let models: URL
    /// Where Core ML keeps its compiled copy of the encoders, outside `models` and not written by us. Nil when the
    /// caller has no such folder to account for, as in most tests.
    public let coreMLCache: URL?

    public init(models: URL, coreMLCache: URL? = nil) {
        self.models = models
        self.coreMLCache = coreMLCache
    }

    public init(paths: AppPaths) {
        self.init(models: paths.models, coreMLCache: paths.coreMLCache)
    }

    public var staging: URL {
        models.appending(path: Self.stagingDirectoryName, directoryHint: .isDirectory)
    }

    /// Where a finished artefact lives. For an archive this is never reached — see `coreMLEncoder(for:)`.
    public func installed(_ artifact: ModelArtifact) -> URL {
        models.appending(path: artifact.file, directoryHint: .notDirectory)
    }

    public func staged(_ artifact: ModelArtifact) -> URL {
        staging.appending(path: artifact.file, directoryHint: .notDirectory)
    }

    public func resumeSidecar(_ artifact: ModelArtifact) -> URL {
        staging.appending(path: artifact.file + Self.resumeSuffix, directoryHint: .notDirectory)
    }

    /// Scratch directory `ditto` unpacks into, before the rename onto the derived encoder path.
    public func extraction(_ artifact: ModelArtifact) -> URL {
        staging.appending(path: artifact.file + ".extract", directoryHint: .isDirectory)
    }

    public func weights(for tier: ModelTier) -> URL {
        installed(ModelCatalog.entry(for: tier).weights)
    }

    /// The one line that makes Core ML actually load.
    ///
    /// whisper.cpp does not accept an encoder path: it takes the weights path, strips `.bin` and appends
    /// `-encoder.mlmodelc`. Our weights are quantised, so it looks for `ggml-small-q8_0-encoder.mlmodelc` while
    /// the published zip unpacks to `ggml-small-encoder.mlmodelc`. Installing under the zip's own name costs
    /// nothing visible — the model still loads, just on Metal alone — which is why `CoreMLEncoderPathTests`
    /// pins both names rather than trusting a code review to notice.
    public func coreMLEncoder(for tier: ModelTier) -> URL {
        ModelInstallation.coreMLEncoderURL(for: weights(for: tier))
    }
}

/// The pause sidecar. Written when a download is cancelled for a pause or a quit, read at the next launch.
///
/// The byte counts are the whole tier's, not this artefact's: they are what the row's progress bar shows, and a
/// tier is up to two downloads. `resumeData` is the transport's own opaque blob, or nil when it made none.
public struct ResumeRecord: Codable, Sendable, Equatable {
    public let file: String
    public let receivedBytes: Int64
    public let expectedBytes: Int64
    public let resumeData: Data?

    public init(file: String, receivedBytes: Int64, expectedBytes: Int64, resumeData: Data?) {
        self.file = file
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.resumeData = resumeData
    }

    public var progress: DownloadProgress {
        DownloadProgress(receivedBytes: receivedBytes, expectedBytes: expectedBytes)
    }
}
