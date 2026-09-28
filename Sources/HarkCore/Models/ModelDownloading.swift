import Foundation

public enum DownloadOutcome: Sendable, Equatable {
    case completed
    /// The caller cancelled in order to pause. The resume data is nil when the transport could not produce any,
    /// in which case the row still reads Paused and clicking Resume starts the artefact over.
    case paused(resumeData: Data?)
}

/// Fetching one catalogue artefact to a local file.
///
/// Pausing is Swift cancellation: cancel the task running `download` and it returns `.paused` carrying whatever
/// resume data the transport managed to produce. It deliberately does not throw `CancellationError` — a pause is
/// an outcome the user asked for rather than a failure, and the resume data has to survive it.
public protocol ModelDownloading: Sendable {
    func download(
        _ artifact: ModelArtifact,
        to destination: URL,
        resuming resumeData: Data?,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws(ModelInstallFailure) -> DownloadOutcome

    /// Frees whatever the transport kept on disk so that `resumeData` could be resumed.
    ///
    /// Called when a paused download is abandoned instead of resumed. The transport keeps the partial bytes
    /// outside the models folder, referenced only from inside the resume data, so once that data is thrown
    /// away nothing else will ever point at them again — they would sit in the system temp directory until
    /// something else cleaned it.
    func discardResumeData(_ resumeData: Data)
}

extension ModelDownloading {
    /// A transport that keeps nothing between attempts has nothing to free.
    public func discardResumeData(_ resumeData: Data) {}
}
