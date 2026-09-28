import Foundation
import HarkCore
import Testing

private typealias F = Fixture

@Suite struct LogHistoryTests {
    private static func record(at date: Date) -> UtteranceRecord {
        UtteranceRecord(
            context: F.context(pressedAt: date, capture: F.speech), transcript: F.transcript, outcome: .textInserted)
    }

    /// Only day files go: a note, a backup and a folder the user keeps beside the log stay.
    @Test func clearingDeletesTheDayFilesAndNothingElse() throws {
        let directory = try TemporaryDirectory()
        let log = UtteranceLog(directory: directory.url, timeZone: F.paris)
        #expect(log.append(Self.record(at: F.pressedAt)))
        #expect(log.append(Self.record(at: F.pressedAt.addingTimeInterval(86_400))))
        let kept = ["notes.txt", "2026-09-28.jsonl.bak", "2026-9-28.jsonl"]
        for name in kept {
            try Data("x".utf8).write(to: directory.url.appending(path: name))
        }
        try FileManager.default.createDirectory(
            at: directory.url.appending(path: "old", directoryHint: .isDirectory), withIntermediateDirectories: true)

        #expect(try LogHistory.clear(in: directory.url) == 2)

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.url.path(percentEncoded: false))
        #expect(Set(left) == Set(kept + ["old"]))
        #expect(LogReader(directory: directory.url).read().entries.isEmpty)
    }

    @Test func aMissingFolderIsAnEmptyHistory() throws {
        let directory = try TemporaryDirectory()
        let missing = directory.url.appending(path: "logs", directoryHint: .isDirectory)
        #expect(try LogHistory.clear(in: missing) == 0)
    }

    /// The contract holds after a clear: the next utterance writes its line into a new file.
    @Test func theNextUtteranceStillWritesItsLine() throws {
        let directory = try TemporaryDirectory()
        let log = UtteranceLog(directory: directory.url, timeZone: F.paris)
        #expect(log.append(Self.record(at: F.pressedAt)))
        try LogHistory.clear(in: directory.url)

        #expect(log.append(Self.record(at: F.pressedAt.addingTimeInterval(60))))
        #expect(LogReader(directory: directory.url).read().entries.count == 1)
    }
}
