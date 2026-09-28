import AppKit
import HarkCore
import os

/// The general pasteboard, or a private one for the self-test. Main-actor isolated, reached
/// through HarkCore's async seam.
@MainActor
final class AppKitPasteboard: PasteboardFacade {
    private let pasteboard: NSPasteboard
    /// The promise on the pasteboard now, kept alive here as well as by its item until the next write.
    private var promised: PromisedText?

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func promise(_ text: String, markers: Set<String>, onRead: @escaping @Sendable () -> Void) async -> Int? {
        let provider = PromisedText(text, onRead: onRead)
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: [.string]) else { return nil }
        for marker in markers.sorted() {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return nil }
        promised = provider
        return pasteboard.changeCount
    }

    func write(_ text: String, markers: Set<String>) async -> Int? {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return nil }
        for marker in markers.sorted() {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item]) ? pasteboard.changeCount : nil
    }

    func changeCount() async -> Int {
        pasteboard.changeCount
    }

    func snapshot() async -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardSnapshot.Item(
                item.types.compactMap { type in
                    item.data(forType: type).map { PasteboardSnapshot.Representation(type: type.rawValue, data: $0) }
                })
        }
        return PasteboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    func restore(_ snapshot: PasteboardSnapshot, ifChangeCountIs expected: Int) async -> Bool {
        guard pasteboard.changeCount == expected else { return false }
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return true }
        let items = snapshot.items.map { saved in
            let item = NSPasteboardItem()
            for representation in saved.representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        return pasteboard.writeObjects(items)
    }
}

/// Text handed over only when a reader asks for it. AppKit calls the provider on the main thread, from inside the
/// reader's request, so the first call is the moment the paste landed.
private nonisolated final class PromisedText: NSObject, NSPasteboardItemDataProvider, Sendable {
    private let text: String
    private let onRead: @Sendable () -> Void
    private let read = OSAllocatedUnfairLock(initialState: false)

    init(_ text: String, onRead: @escaping @Sendable () -> Void) {
        self.text = text
        self.onRead = onRead
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setString(text, forType: type)
        let first = read.withLock { read in
            defer { read = true }
            return !read
        }
        if first { onRead() }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}
