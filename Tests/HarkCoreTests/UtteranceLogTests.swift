import Foundation
import HarkCore
import Testing

private typealias F = Fixture

@Suite struct UtteranceLogTests {
    private func record(at date: Date, _ outcome: PipelineOutcome = .discarded(.cancelled)) -> UtteranceRecord {
        UtteranceRecord(context: F.context(pressedAt: date), transcript: nil, outcome: outcome)
    }

    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    @Test func oneLinePerAppend() throws {
        let directory = try TemporaryDirectory()
        let log = UtteranceLog(directory: directory.url.appending(path: "logs"), timeZone: F.paris)
        let records = [
            record(at: F.pressedAt, .discarded(.busy)),
            record(at: F.pressedAt.addingTimeInterval(5), .failed(.modelMissing(.small))),
            record(at: F.pressedAt.addingTimeInterval(9)),
        ]
        for record in records {
            #expect(log.append(record))
        }

        let url = log.fileURL(for: F.pressedAt)
        #expect(url.lastPathComponent == "2026-09-18.jsonl")
        #expect(try lines(url) == records.map { $0.jsonLine(timeZone: F.paris) } + [""])
    }

    @Test func newFileAfterMidnight() throws {
        let directory = try TemporaryDirectory()
        let log = UtteranceLog(directory: directory.url, timeZone: F.paris)
        let clock = ManualWallClock(F.beforeMidnight)

        log.append(record(at: clock.now()))
        clock.advance(by: 0.2)
        log.append(record(at: clock.now()))

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.url.path(percentEncoded: false))
        #expect(files.sorted() == ["2026-09-18.jsonl", "2026-09-19.jsonl"])
        #expect(try lines(directory.url.appending(path: "2026-09-18.jsonl")).count == 2)
        #expect(try lines(directory.url.appending(path: "2026-09-19.jsonl")).count == 2)
    }

    @Test func utteranceThatStraddlesMidnightStaysInItsFirstDay() throws {
        let directory = try TemporaryDirectory()
        let log = UtteranceLog(directory: directory.url, timeZone: F.paris)
        var context = UtteranceContext(id: F.id, pressedAt: F.beforeMidnight)
        context.releasedAt = F.beforeMidnight.addingTimeInterval(3)

        log.append(UtteranceRecord(context: context, transcript: nil, outcome: .discarded(.cancelled)))

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.url.path(percentEncoded: false))
        #expect(files == ["2026-09-18.jsonl"])
    }

    @Test func dayFollowsTheLogTimeZone() {
        let utc = UtteranceLog(directory: URL(filePath: "/tmp"), timeZone: .gmt)
        let paris = UtteranceLog(directory: URL(filePath: "/tmp"), timeZone: F.paris)
        #expect(utc.fileURL(for: F.beforeMidnight).lastPathComponent == "2026-09-18.jsonl")
        #expect(paris.fileURL(for: F.beforeMidnight.addingTimeInterval(1)).lastPathComponent == "2026-09-19.jsonl")
    }

    @Test func filesArePrivate() throws {
        let directory = try TemporaryDirectory()
        let logs = directory.url.appending(path: "logs")
        let log = UtteranceLog(directory: logs, timeZone: F.paris)
        log.append(record(at: F.pressedAt))

        let manager = FileManager.default
        let file = try manager.attributesOfItem(atPath: log.fileURL(for: F.pressedAt).path(percentEncoded: false))
        let folder = try manager.attributesOfItem(atPath: logs.path(percentEncoded: false))
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func appendReportsFailureWithoutThrowing() throws {
        let directory = try TemporaryDirectory()
        let blocked = directory.url.appending(path: "logs")
        try Data("not a directory".utf8).write(to: blocked)

        #expect(UtteranceLog(directory: blocked, timeZone: F.paris).append(record(at: F.pressedAt)) == false)
    }
}
