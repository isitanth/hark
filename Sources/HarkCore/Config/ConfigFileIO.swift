import Foundation

/// POSIX file operations for `ConfigStore`, reporting `errno` rather than a `CocoaError`, because the snapshot and
/// `ConfigWriteError` carry the number.
enum ConfigFileIO {
    struct Failure: Error {
        let errno: Int32
    }

    /// The whole file, or the errno of the first call that failed. ENOENT when it is missing.
    static func read(_ url: URL) -> Result<Data, Failure> {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(Failure(errno: errno)) }
        defer { close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(Failure(errno: errno))
            }
            if count == 0 { return .success(data) }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    /// Nil when the file cannot be read, for whatever reason.
    static func contents(_ url: URL) -> Data? {
        try? read(url).get()
    }

    /// Creates `directory` and its parents; the last component gets `mode`. An existing directory is left alone.
    static func ensureDirectory(_ directory: URL, mode: Int16 = 0o700) throws(Failure) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: mode)])
        } catch {
            throw Failure(errno: posixCode(of: error))
        }
    }

    /// Writes `data` to a temporary file next to `url`, then rename(2)s it over `url`. The new file keeps the mode
    /// of the one it replaces, or 0600 when there was none. A symlink is followed to the file it names (see
    /// `target(of:)`): renaming over the link would replace the link itself, and the file it points to — in a dotfiles
    /// repository, say — would silently stop getting the edits.
    static func replace(_ url: URL, with data: Data) throws(Failure) {
        let url = try target(of: url)
        let path = url.path(percentEncoded: false)
        var existing = stat()
        let mode: mode_t = stat(path, &existing) == 0 ? existing.st_mode & 0o7777 : 0o600
        let directory = url.deletingLastPathComponent().path(percentEncoded: false)
        var template = Array("\(directory)/.\(url.lastPathComponent).XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw Failure(errno: errno) }
        let temporary = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var failure: Int32 = 0
        if fchmod(descriptor, mode) != 0 { failure = errno }
        if failure == 0 { failure = writeAll(data, to: descriptor) }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        if close(descriptor) != 0, failure == 0 { failure = errno }
        if failure == 0, rename(temporary, path) != 0 { failure = errno }
        if failure != 0 {
            unlink(temporary)
            throw Failure(errno: failure)
        }
    }

    /// The file a write at `url` changes: `url`, or for a symlink the file it names, through up to eight links, each
    /// relative target resolved against its link's directory. A dangling link resolves to the path it names, so the
    /// write creates that file when its directory exists and fails, leaving the link alone, when it does not.
    static func target(of url: URL) throws(Failure) -> URL {
        var current = url
        // Eight links followed, and a ninth look at where the last one led.
        for _ in 0...8 {
            let path = current.path(percentEncoded: false)
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return current }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(path, &buffer, buffer.count - 1)
            guard length > 0 else { throw Failure(errno: errno) }
            let destination = String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            current =
                destination.hasPrefix("/")
                ? URL(filePath: destination) : current.deletingLastPathComponent().appending(path: destination)
        }
        throw Failure(errno: ELOOP)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Int32 {
        data.withUnsafeBytes { bytes -> Int32 in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return 0
        }
    }

    private static func posixCode(of error: any Error) -> Int32 {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        if let underlying, underlying.domain == NSPOSIXErrorDomain { return Int32(underlying.code) }
        return EIO
    }
}
