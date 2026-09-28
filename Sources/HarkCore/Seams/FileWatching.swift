import Foundation

/// Watches a path, not an inode.
///
/// Editors save in two ways. Some write the file in place; vim, most IDEs and `Data.write(options: .atomic)` write a
/// new file and rename it over the old one, which leaves a watcher on the old descriptor watching a file that no
/// longer has a name. An implementation must notice both, keep going after the file is renamed away or deleted, and
/// pick the path up again when something is created there.
public protocol FileWatching: Sendable {
    /// One element per change noticed at `url`: its contents written, or the file replaced, renamed, deleted or
    /// created. Changes arrive in bursts — one save can be three or four events — so consumers debounce. Watching
    /// stops when the consumer stops iterating.
    func changes(of url: URL) -> AsyncStream<Void>
}

/// `DispatchSource` vnode sources on the file and on its parent directory. The directory source sees renames,
/// deletions and creations; the file source sees in-place writes, and is re-opened whenever the path starts naming
/// a different file.
public struct DispatchFileWatcher: FileWatching {
    public init() {}

    public func changes(of url: URL) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let watch = PathWatch(url: url, continuation: continuation)
        continuation.onTermination = { _ in watch.cancel() }
        watch.start()
        return stream
    }
}

/// One watched path.
///
/// `@unchecked Sendable`: every mutable property is read and written only on `queue`, a private serial queue that is
/// also the target of both dispatch sources. `start()` and `cancel()` hop onto it; nothing else touches the state.
private final class PathWatch: @unchecked Sendable {
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private let path: String
    private let directoryPath: String
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "hark.config.file-watch")

    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var fileIdentity: FileIdentity?
    private var cancelled = false

    init(url: URL, continuation: AsyncStream<Void>.Continuation) {
        path = url.path(percentEncoded: false)
        directoryPath = url.deletingLastPathComponent().path(percentEncoded: false)
        self.continuation = continuation
    }

    /// Synchronous, so the path is watched by the time `changes(of:)` returns: a change made a moment later — or between
    /// the caller subscribing and reading the file — is not lost.
    func start() {
        queue.sync { [self] in
            guard !cancelled else { return }
            directorySource = makeSource(
                path: directoryPath, mask: [.write, .rename, .delete, .link]
            ) { [weak self] _ in
                guard let self else { return }
                continuation.yield()
                rearmFileSource()
            }
            rearmFileSource()
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            directorySource?.cancel()
            directorySource = nil
            closeFileSource()
        }
    }

    /// Re-opens the file source if the path now names a different file, or has appeared; drops it if the path is gone.
    private func rearmFileSource() {
        guard !cancelled else { return }
        let identity = Self.identity(of: path)
        guard identity != fileIdentity || fileSource == nil else { return }
        closeFileSource()
        guard identity != nil else { return }
        fileSource = makeSource(
            path: path, mask: [.write, .extend, .attrib, .delete, .rename, .revoke, .link]
        ) { [weak self] events in
            guard let self else { return }
            continuation.yield()
            if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
                rearmFileSource()
            }
        }
        fileIdentity = fileSource == nil ? nil : identity
    }

    private func closeFileSource() {
        fileSource?.cancel()
        fileSource = nil
        fileIdentity = nil
    }

    private func makeSource(
        path: String, mask: DispatchSource.FileSystemEvent,
        handler: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: queue)
        source.setEventHandler { [unowned source] in handler(source.data) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private static func identity(of path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }
}
