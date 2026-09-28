import Foundation
import os

/// Appends utterance records to `<directory>/YYYY-MM-DD.jsonl`, one line each. The day comes from the
/// record's key-down time in `timeZone`, so an utterance that straddles midnight lands in the file of the day it began.
public struct UtteranceLog: Sendable {
    public let directory: URL
    public let timeZone: TimeZone

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "utterance-log")

    public init(directory: URL, timeZone: TimeZone = .autoupdatingCurrent) {
        self.directory = directory
        self.timeZone = timeZone
    }

    public func fileURL(for date: Date) -> URL {
        let day = Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day().dateSeparator(.dash).format(date)
        return directory.appending(path: "\(day).jsonl", directoryHint: .notDirectory)
    }

    /// Never throws. A failed write goes to the unified log and returns false; the caller decides whether that
    /// becomes a health warning.
    @discardableResult
    public func append(_ record: UtteranceRecord) -> Bool {
        let url = fileURL(for: record.timestamp)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            Self.logger.error("cannot create \(directory.path(percentEncoded: false)): \(error.localizedDescription)")
            return false
        }

        let fd = open(url.path(percentEncoded: false), O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            Self.logger.error("cannot open \(url.lastPathComponent): errno \(errno)")
            return false
        }
        defer { close(fd) }

        let line = Data((record.jsonLine(timeZone: timeZone) + "\n").utf8)
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else {
            Self.logger.error(
                "short write to \(url.lastPathComponent): \(written) of \(line.count) bytes, errno \(errno)")
            return false
        }
        return true
    }
}
