import Foundation

/// Everything on the general pasteboard at one moment: every item, every type, in the order the owner wrote them,
/// so putting it back gives readers the same preferred type. Promised data is read, and so fulfilled, when taken.
public struct PasteboardSnapshot: Sendable, Equatable {
    public struct Representation: Sendable, Equatable {
        /// A UTI such as `public.utf8-plain-text`.
        public var type: String
        public var data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public struct Item: Sendable, Equatable {
        public var representations: [Representation]

        public init(_ representations: [Representation]) {
            self.representations = representations
        }
    }

    public var items: [Item]

    /// The first item's plain text, as a reader asking for a string would get it.
    public var plainText: String? {
        items.first?.representations.first { $0.type == "public.utf8-plain-text" }
            .map { String(decoding: $0.data, as: UTF8.self) }
    }

    /// `NSPasteboard.changeCount` when the snapshot was taken.
    public var changeCount: Int

    public init(items: [Item], changeCount: Int) {
        self.items = items
        self.changeCount = changeCount
    }
}

/// The markers from nspasteboard.org that clipboard managers honour.
public enum PasteboardMarker {
    /// The content is on the pasteboard only for a moment: do not record it.
    public static let transient = "org.nspasteboard.TransientType"
    /// The content is a secret: do not record or show it.
    public static let concealed = "org.nspasteboard.ConcealedType"
}

/// AppKit-backed (NSPasteboard). Async for the same reason as `Workspace`.
public protocol PasteboardFacade: Sendable {
    /// Replaces the contents with `text`, plus the transient and concealed markers asked for. Returns the change count
    /// after the write, or nil when it failed.
    func write(_ text: String, markers: Set<String>) async -> Int?
    /// Like `write`, but the text is a promise: its bytes are produced only when a reader asks for them, and `onRead`
    /// runs the first time one does. That is how a paste learns that an app took the text.
    func promise(_ text: String, markers: Set<String>, onRead: @escaping @Sendable () -> Void) async -> Int?
    func changeCount() async -> Int
    func snapshot() async -> PasteboardSnapshot
    /// Replaces the contents with `snapshot`'s items, but only while the change count is still `expected`: in one
    /// main-actor turn, so a copy the user makes in between is never overwritten. An empty snapshot leaves the
    /// pasteboard empty. False when the count had moved or the write failed.
    func restore(_ snapshot: PasteboardSnapshot, ifChangeCountIs expected: Int) async -> Bool
}

extension PasteboardFacade {
    /// For text the user is meant to paste: no transient marker, concealed when it came from a secure field.
    public func writeText(_ text: String, concealed: Bool = false) async -> Bool {
        await write(text, markers: concealed ? [PasteboardMarker.concealed] : []) != nil
    }
}
