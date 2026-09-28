import Foundation
import Testing

@testable import HarkCore

private typealias F = Fixture

@Suite struct RecentFeedTests {
    /// An entry `second` seconds after the fixture's press, named for it so expectations read as a list of seconds.
    private static func entry(_ second: Int, _ resolution: Resolution = .textInserted) -> LogEntry {
        LogEntry(
            id: "\(second)", timestamp: F.pressedAt.addingTimeInterval(TimeInterval(second)), resolution: resolution)
    }

    private static func feed(_ entries: [LogEntry], capacity: Int = RecentFeed.defaultCapacity) -> RecentFeed {
        var feed = RecentFeed(capacity: capacity)
        for entry in entries {
            feed.append(entry)
        }
        return feed
    }

    @Test func anEmptyFeedShowsNothing() {
        let feed = RecentFeed()
        #expect(feed.last == nil)
        #expect(feed.recent.isEmpty)
        #expect(feed.capacity == 50)
    }

    /// LAST says what the newest press did, discard or not; RECENT skips discards and never repeats LAST.
    @Test(arguments: [
        ([entry(0)], "0", [String]()),
        ([entry(0), entry(1, .command)], "1", ["0"]),
        ([entry(0), entry(1, .discarded)], "1", ["0"]),
        ([entry(0, .discarded)], "0", []),
        ([entry(0, .discarded), entry(1, .discarded)], "1", []),
        ([entry(0), entry(1, .discarded), entry(2, .command), entry(3, .discarded), entry(4)], "4", ["2", "0"]),
        (
            [entry(0, .textClipboard), entry(1, .failed), entry(2, .discarded), entry(3, .command)], "3",
            ["1", "0"]
        ),
    ])
    func lastAndRecent(_ appended: [LogEntry], _ last: String, _ recent: [String]) {
        let feed = Self.feed(appended)
        #expect(feed.last?.id == last)
        #expect(feed.recent.map(\.id) == recent)
    }

    /// Discards are skipped before the capacity is applied, so a run of mis-taps does not shorten RECENT.
    @Test(arguments: [1, 3, 5, 8])
    func recentHoldsUpToCapacity(_ capacity: Int) {
        let appended = (0..<20).map { Self.entry($0, $0.isMultiple(of: 3) ? .discarded : .textInserted) }
        let feed = Self.feed(appended, capacity: capacity)

        let expected = (0..<19).reversed().filter { !$0.isMultiple(of: 3) }.prefix(capacity).map(String.init)
        #expect(feed.last?.id == "19")
        #expect(feed.recent.map(\.id) == Array(expected))
        #expect(feed.recent.count == capacity)
    }

    /// Fifty rows, five of them on screen and the rest a scroll away.
    @Test func theDefaultCapacityIsFiftyAndFiveShow() {
        let feed = Self.feed((0..<60).map { Self.entry($0) })
        #expect(feed.recent.map(\.id) == (9..<59).reversed().map(String.init))
        #expect(RecentFeed.visibleRows == 5)
    }

    @Test(arguments: [
        [0, 1, 2, 3, 4, 5],
        [5, 4, 3, 2, 1, 0],
        [3, 0, 5, 1, 4, 2],
    ])
    func newestFirstWhateverTheOrderAppendedOrSeeded(_ seconds: [Int]) {
        var seeded = RecentFeed()
        seeded.seed(seconds.map { Self.entry($0) })
        let appended = Self.feed(seconds.map { Self.entry($0) })

        for feed in [seeded, appended] {
            #expect(feed.last?.id == "5")
            #expect(feed.recent.map(\.id) == ["4", "3", "2", "1", "0"])
        }
    }

    /// The seed is read off the main actor and can land after the first live utterance. That utterance is in the
    /// log too, so it arrives twice: once live, once in the seed.
    @Test func aSeedLandingAfterALiveEntryMergesWithoutDuplicates() {
        var feed = RecentFeed()
        feed.append(Self.entry(9, .command))
        feed.append(Self.entry(10))

        feed.seed([Self.entry(10), Self.entry(9, .command), Self.entry(8), Self.entry(7, .discarded), Self.entry(6)])

        #expect(feed.last?.id == "10")
        #expect(feed.recent.map(\.id) == ["9", "8", "6"])
    }

    /// The same, through the real writer and reader: key-down times with sub-millisecond parts, which the log drops.
    @Test func theLiveEntryAndItsLineReadBackAreOneEntry() throws {
        let directory = try TemporaryDirectory()
        let log = UtteranceLog(directory: directory.url, timeZone: F.paris)
        let records = [0.000_4, 1.000_7, 2.345_678_9, 3.999_9].map { offset in
            UtteranceRecord(
                context: F.context(pressedAt: F.pressedAt.addingTimeInterval(offset), capture: F.speech),
                transcript: F.transcript, outcome: .textInserted)
        }
        for record in records {
            #expect(log.append(record))
        }
        var feed = RecentFeed()
        for record in records.suffix(2) {
            feed.append(LogEntry(record: record))
        }

        feed.seed(LogReader(directory: directory.url).read().entries)

        // Whichever copy arrived first is the one kept: the live ones here.
        #expect(feed.last == LogEntry(record: records[3]))
        #expect(feed.last?.id.hasPrefix("live:") == true)
        #expect(
            feed.recent.map(\.id) == [LogEntry(record: records[2]).id, "2026-09-18.jsonl:2", "2026-09-18.jsonl:1"])
    }

    @Test func anEntryAlreadyHeldIsNotReplacedByOneWithTheSameTimestamp() {
        var feed = RecentFeed()
        feed.append(LogEntry(id: "live", timestamp: F.pressedAt, resolution: .command))

        feed.seed([LogEntry(id: "disk", timestamp: F.pressedAt, resolution: .command)])
        feed.append(LogEntry(id: "again", timestamp: F.pressedAt, resolution: .failed))

        #expect(feed.last?.id == "live")
        #expect(feed.recent.isEmpty)
    }

    /// A real entry behind `retained - 1` newer discards is still in RECENT; one more discard and it is gone. So
    /// the bound is what limits how many mis-taps RECENT can see past.
    @Test func theFeedRetainsABoundedHistory() {
        let discards = (1..<RecentFeed.retained).map { Self.entry($0, .discarded) }
        var feed = Self.feed([Self.entry(0)] + discards)

        #expect(feed.last?.id == "\(RecentFeed.retained - 1)")
        #expect(feed.recent.map(\.id) == ["0"])

        feed.append(Self.entry(RecentFeed.retained, .discarded))

        #expect(feed.recent.isEmpty)
    }

    /// A seed larger than the bound keeps its newest entries, however it was ordered.
    @Test func aLargeSeedKeepsItsNewestEntries() {
        var feed = RecentFeed()
        let seed = (0..<(RecentFeed.retained * 3)).map { Self.entry($0, $0 == 0 ? .textInserted : .discarded) }

        feed.seed(seed.reversed())

        #expect(feed.last?.id == "\(RecentFeed.retained * 3 - 1)")
        #expect(feed.recent.isEmpty, "entry 0 is older than the bound")
        #expect(RecentFeed.retained > RecentFeed.defaultCapacity)
    }
}
