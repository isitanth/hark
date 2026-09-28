import Foundation
import os

/// The real `ModelDownloading`: one URLSession download task per artefact, with progress, pause-to-resume-data,
/// and the origin allow-list applied to the first request and to every redirect.
///
/// Hugging Face answers the pinned URL with a signed redirect to `cdn-lfs*.huggingface.co` that expires. Resume
/// data carries that expired target inside it, so a transfer paused for long enough comes back 403 even though
/// the bytes on disk are fine. That is the one retry below: throw the resume data away and start again from the
/// pinned URL, which mints a fresh signature.
public final class URLSessionDownloader: ModelDownloading {
    private let configuration: URLSessionConfiguration

    fileprivate static let logger = Logger(subsystem: HarkLog.subsystem, category: "downloads")

    public init(configuration: URLSessionConfiguration = URLSessionDownloader.defaultConfiguration()) {
        self.configuration = configuration
    }

    /// `timeoutIntervalForRequest` is an inactivity timer rather than a budget for the whole transfer: a minute
    /// without a single byte is a dead connection, while large-v3 over a slow link is legitimately hours, which
    /// is why `timeoutIntervalForResource` keeps its week-long default. Caching is off because the artefacts are
    /// hundreds of megabytes and we already keep the only copy that matters.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }

    public func download(
        _ artifact: ModelArtifact,
        to destination: URL,
        resuming resumeData: Data?,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws(ModelInstallFailure) -> DownloadOutcome {
        // The catalogue is compiled in, so this can only fire on a fixture table — but it is also the check that
        // makes the redirect rule total rather than "every hop after the first".
        if let rejection = DownloadOriginPolicy.rejection(for: artifact.url) { throw rejection }

        if resumeData != nil {
            switch await attempt(artifact, to: destination, resuming: resumeData, progress: progress) {
            case .completed: return .completed
            case .paused(let data): return .paused(resumeData: data)
            case .failed(let failure): throw failure
            case .expired:
                Self.logger.warning("\(artifact.file, privacy: .public): signed URL expired, restarting from pinned")
            }
        }

        switch await attempt(artifact, to: destination, resuming: nil, progress: progress) {
        case .completed: return .completed
        case .paused(let data): return .paused(resumeData: data)
        case .failed(let failure): throw failure
        // A 403 on the pinned URL itself is a real refusal, not a stale signature: there is nothing left to
        // restart from, so it surfaces as the HTTP status it is.
        case .expired: throw .http(403)
        }
    }

    /// One transfer, start to finish. A session is created per attempt and invalidated afterwards; sharing one
    /// would mean a task-identifier map whose entries outlive their transfers, and a session costs nothing next
    /// to a gigabyte on the wire.
    private func attempt(
        _ artifact: ModelArtifact,
        to destination: URL,
        resuming resumeData: Data?,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async -> Transfer.Outcome {
        let transfer = Transfer(artifact: artifact, destination: destination, progress: progress)
        let queue = OperationQueue()
        // Serial, so the delegate callbacks cannot interleave with each other and the lock only ever arbitrates
        // between them and the cancellation handler.
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: queue)
        // A session holds its delegate strongly until it is invalidated, so this is what breaks the cycle.
        defer { session.finishTasksAndInvalidate() }

        let task =
            if let resumeData {
                session.downloadTask(withResumeData: resumeData)
            } else {
                session.downloadTask(with: URLRequest(url: artifact.url))
            }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                transfer.begin(task, continuation)
            }
        } onCancel: {
            transfer.pause()
        }
    }
}

/// The URLSession delegate for one transfer, bridging its callbacks to a single continuation.
///
/// `@unchecked Sendable` with an explicit lock rather than `OSAllocatedUnfairLock`, because the state it guards
/// includes a `URLSessionDownloadTask`, which is not `Sendable`. Everything mutable lives behind `lock`, and
/// `finish` resolves exactly once: whichever callback arrives first wins and the rest are dropped.
private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Outcome: Sendable {
        case completed
        case paused(Data?)
        /// HTTP 403: the CDN's signed target is time-limited and this one is past it.
        case expired
        case failed(ModelInstallFailure)
    }

    private let artifact: ModelArtifact
    private let destination: URL
    private let progress: @Sendable (DownloadProgress) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var task: URLSessionDownloadTask?
    private var pausing = false
    private var resolved = false
    /// Set by the redirect callback, read back once the task finishes. Recording beats cancelling from inside
    /// the delegate: it keeps the refusal on one code path instead of racing a cancel against a completion.
    private var rejection: ModelInstallFailure?

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "downloads")

    init(
        artifact: ModelArtifact,
        destination: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) {
        self.artifact = artifact
        self.destination = destination
        self.progress = progress
    }

    // MARK: Lifecycle

    /// Stores the continuation and starts the task under the lock, so a `pause()` racing in from the
    /// cancellation handler either precedes the start or cancels a task that is already running.
    func begin(_ task: URLSessionDownloadTask, _ continuation: CheckedContinuation<Outcome, Never>) {
        let cancelledBeforeStart: Bool = lock.withLock {
            self.continuation = continuation
            self.task = task
            guard !pausing else { return true }
            task.resume()
            return false
        }
        guard cancelledBeforeStart else { return }
        // Paused before the first byte, so there is nothing resumable. The row still reads Paused; clicking it
        // starts the artefact over.
        task.cancel()
        finish(.paused(nil))
    }

    func pause() {
        let task: URLSessionDownloadTask? = lock.withLock {
            pausing = true
            return self.task
        }
        // This callback is always invoked, with nil when the transfer produced nothing resumable, which is what
        // makes a pause guaranteed to resolve rather than dependent on `didCompleteWithError` carrying the data.
        task?.cancel(byProducingResumeData: { data in self.finish(.paused(data)) })
    }

    private func finish(_ outcome: Outcome) {
        let continuation: CheckedContinuation<Outcome, Never>? = lock.withLock {
            guard !resolved, let continuation = self.continuation else { return nil }
            resolved = true
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: outcome)
    }

    // MARK: Delegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // The catalogue's declared size, not `totalBytesExpectedToWrite`: on a resumed transfer the server's
        // length covers only the remaining range, which would send the bar backwards.
        progress(DownloadProgress(receivedBytes: totalBytesWritten, expectedBytes: artifact.byteCount))
    }

    /// Puts the bar where the resumed file already is, before the first chunk of the new range lands.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        progress(DownloadProgress(receivedBytes: fileOffset, expectedBytes: artifact.byteCount))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url, let rejection = DownloadOriginPolicy.rejection(for: target) else {
            completionHandler(request)
            return
        }
        Self.logger.error("refused redirect: \(rejection.code, privacy: .public)")
        lock.withLock { self.rejection = rejection }
        // nil declines the hop; the task then completes on the redirect response and the refusal is read back
        // in `didFinishDownloadingTo`.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let rejection = lock.withLock({ self.rejection }) {
            finish(.failed(rejection))
            return
        }
        // A download task writes any response body to disk, including an error page, so the status is checked
        // here rather than left to `didCompleteWithError`, which sees no error at all for a 4xx.
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(.failed(.transport("no HTTP response")))
            return
        }
        guard (200...299).contains(response.statusCode) else {
            finish(response.statusCode == 403 ? .expired : .failed(.http(response.statusCode)))
            return
        }
        // `location` is only valid for the duration of this call, so the move happens inline.
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: location, to: destination)
        } catch {
            finish(.failed(.filesystem(error.localizedDescription)))
            return
        }
        finish(.completed)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // Success has already been reported by `didFinishDownloadingTo`, which owns the moved file.
        guard let error else { return }
        if let rejection = lock.withLock({ self.rejection }) {
            finish(.failed(rejection))
            return
        }
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled else {
            finish(.failed(.transport(failure.localizedDescription)))
            return
        }
        if let data = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            // Taking it here as well as from `cancel(byProducingResumeData:)` is only worth doing when the data
            // is actually present: `finish` is first-wins, and winning with nil would discard bytes the other
            // path still holds.
            finish(.paused(data))
        } else if !lock.withLock({ pausing }) {
            // Cancelled by something other than a pause — the session going away, say. Not a resolution path we
            // can wait on, so it fails rather than hanging the caller.
            finish(.failed(.transport("cancelled")))
        }
    }
}

extension URLSessionDownloader {
    /// Deletes the partial file a paused download left in the temp directory.
    ///
    /// Pausing with `cancel(byProducingResumeData:)` keeps the bytes received so far on purpose, in a
    /// `CFNetworkDownload_*.tmp` file in the system temp directory, and records its name inside the resume data.
    /// Abandoning the resume data does not remove that file. Before this existed, every pause followed by a
    /// cancel left one behind — 2.5 GB of them after one afternoon of testing, all outside the models folder
    /// where nothing, purge included, would ever look.
    public func discardResumeData(_ resumeData: Data) {
        guard let name = Self.temporaryFileName(in: resumeData) else {
            Self.logger.info("resume data named no temporary file; nothing to free")
            return
        }
        let file = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .notDirectory)
        do {
            try FileManager.default.removeItem(at: file)
            Self.logger.info("freed \(name, privacy: .public)")
        } catch {
            // Already gone is the common case: a resumed download consumes the file it resumed from.
            Self.logger.debug("\(name, privacy: .public) not freed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The temp file's name, read out of resume data without depending on the archive's internal layout.
    ///
    /// Resume data is an `NSKeyedArchiver` archive whose `NSURLSessionResumeInfoTempFileName` entry holds a bare
    /// file name, relative to the temp directory (observed on macOS 27, 2026-09-21). Rather than resolve the
    /// archiver's UID references, this looks for the one string in `$objects` shaped like that name, which
    /// holds across the archive versions that have shipped. Anything that is not a plain file name is ignored,
    /// so a hostile blob cannot aim the delete outside the temp directory.
    public static func temporaryFileName(in resumeData: Data) -> String? {
        guard
            let archive = try? PropertyListSerialization.propertyList(from: resumeData, format: nil) as? [String: Any],
            let objects = archive["$objects"] as? [Any]
        else { return nil }
        return objects.lazy.compactMap { $0 as? String }.first { name in
            name.hasPrefix("CFNetworkDownload_") && name.hasSuffix(".tmp") && !name.contains("/")
                && name != ".." && name.count < 64
        }
    }
}

extension ModelDownloading where Self == URLSessionDownloader {
    /// The real downloader, spelled so callers never name `URLSession` themselves — the grep lint in
    /// `scripts/check.sh` confines that string to this file, and this is what keeps it there.
    public static var standard: URLSessionDownloader { URLSessionDownloader() }
}
