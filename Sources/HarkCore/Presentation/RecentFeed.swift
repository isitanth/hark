import Foundation

/// The panel's LAST and RECENT sections, seeded from the log at launch and extended by each new record.
///
/// LAST is the newest entry of any kind, so a tap too short to be speech says so. RECENT is what came before it,
/// minus discards: a mis-tap should not push a real dictation out of the list. RECENT shows `visibleRows` and scrolls
/// through the rest (the user's request of 2026-09-28); the whole log is the Log tab's.
public struct RecentFeed: Sendable, Equatable {
    public static let defaultCapacity = 50
    /// Rows the panel shows before RECENT scrolls.
    public static let visibleRows = 5
    /// How many entries are kept at all, and how many log lines launch reads. Discards are filtered out of RECENT,
    /// so this has to exceed its capacity.
    public static let retained = 200

    public let capacity: Int
    /// Newest first, unique by timestamp.
    private var entries: [LogEntry] = []

    public init(capacity: Int = defaultCapacity) {
        self.capacity = capacity
    }

    public var last: LogEntry? { entries.first }

    public var recent: [LogEntry] {
        Array(entries.dropFirst().lazy.filter { $0.resolution != .discarded }.prefix(capacity))
    }

    /// Entries read from disk, in any order. Merged with whatever was appended before the read finished.
    public mutating func seed(_ seeded: [LogEntry]) {
        merge(seeded)
    }

    /// A record the pipeline has just written.
    public mutating func append(_ entry: LogEntry) {
        merge([entry])
    }

    private mutating func merge(_ incoming: [LogEntry]) {
        var seen = Set(entries.map(\.timestamp))
        var merged = entries
        for entry in incoming where seen.insert(entry.timestamp).inserted {
            merged.append(entry)
        }
        entries = Array(merged.sorted { $0.timestamp > $1.timestamp }.prefix(Self.retained))
    }
}
