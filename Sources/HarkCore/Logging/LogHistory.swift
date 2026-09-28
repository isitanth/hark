import Foundation
import os

/// Clears the dictation history: every `YYYY-MM-DD.jsonl` in the log folder, and nothing else in it.
///
/// The user's decision of 2026-09-28: the history is theirs to clear, from the panel or the Log tab, after a
/// confirmation. It deletes the words along with the outcomes, which is the point. Every utterance afterwards still
/// writes its one line; a line written while the clear runs lands in a new file.
public enum LogHistory {
    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "utterance-log")

    /// Deletes the day files and returns how many went. A missing folder is an empty history. A file that cannot be
    /// deleted does not stop the others; the first such error is thrown once all were tried.
    @discardableResult
    public static func clear(in directory: URL) throws -> Int {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        } catch CocoaError.fileReadNoSuchFile {
            return 0
        }
        var deleted = 0
        var firstError: (any Error)?
        for name in names where LogReader.isDayFileName(name) {
            do {
                try FileManager.default.removeItem(at: directory.appending(path: name, directoryHint: .notDirectory))
                deleted += 1
            } catch {
                logger.error("cannot delete \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                firstError = firstError ?? error
            }
        }
        logger.notice("history cleared: \(deleted) day files")
        if let firstError { throw firstError }
        return deleted
    }
}
