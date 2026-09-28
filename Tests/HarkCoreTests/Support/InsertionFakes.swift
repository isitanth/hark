import Foundation
import HarkCore
import os

/// An in-memory general pasteboard: items, a change count that moves on every write, and a record of the writes.
final class FakePasteboard: PasteboardFacade {
    struct Write: Equatable {
        let text: String
        let markers: Set<String>
    }

    private struct State {
        var items: [PasteboardSnapshot.Item]
        var changeCount = 100
        var writes: [Write] = []
        var restores = 0
        var restoreAttempts = 0
        var failWrites = false
        /// The promise on the pasteboard now, if the last write was one.
        var onRead: (@Sendable () -> Void)?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(text: String? = "original") {
        let items = text.map { [Self.item($0)] } ?? []
        state = OSAllocatedUnfairLock(initialState: State(items: items))
    }

    static func item(_ text: String, markers: Set<String> = []) -> PasteboardSnapshot.Item {
        PasteboardSnapshot.Item(
            [PasteboardSnapshot.Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]
                + markers.sorted().map { PasteboardSnapshot.Representation(type: $0, data: Data()) })
    }

    var items: [PasteboardSnapshot.Item] { state.withLock { $0.items } }
    var writes: [Write] { state.withLock { $0.writes } }
    /// Restores that replaced the contents.
    var restores: Int { state.withLock { $0.restores } }
    /// Every call, including the ones refused because the change count had moved.
    var restoreAttempts: Int { state.withLock { $0.restoreAttempts } }

    /// The text of the first item, as a reader asking for plain text would get it.
    var text: String? {
        state.withLock { state in
            state.items.first?.representations.first { $0.type == "public.utf8-plain-text" }
                .map { String(decoding: $0.data, as: UTF8.self) }
        }
    }

    func failNextWrites() { state.withLock { $0.failWrites = true } }

    /// Someone else copies something: what a clipboard manager or the user does in the middle of a paste.
    func userCopies(_ text: String) {
        state.withLock { state in
            state.items = [Self.item(text)]
            state.changeCount += 1
            state.onRead = nil
        }
    }

    func write(_ text: String, markers: Set<String>) async -> Int? {
        state.withLock { state in
            guard !state.failWrites else { return nil }
            state.items = [Self.item(text, markers: markers)]
            state.changeCount += 1
            state.writes.append(Write(text: text, markers: markers))
            state.onRead = nil
            return state.changeCount
        }
    }

    func promise(_ text: String, markers: Set<String>, onRead: @escaping @Sendable () -> Void) async -> Int? {
        let written = await write(text, markers: markers)
        state.withLock { $0.onRead = written == nil ? nil : onRead }
        return written
    }

    /// An app reads the pasteboard, as the target of a ⌘V does: a promise on it learns so.
    func appReads() {
        let onRead = state.withLock { $0.onRead }
        onRead?()
    }

    func changeCount() async -> Int { state.withLock { $0.changeCount } }

    func snapshot() async -> PasteboardSnapshot {
        state.withLock { PasteboardSnapshot(items: $0.items, changeCount: $0.changeCount) }
    }

    func restore(_ snapshot: PasteboardSnapshot, ifChangeCountIs expected: Int) async -> Bool {
        state.withLock { state in
            state.restoreAttempts += 1
            guard state.changeCount == expected else { return false }
            state.items = snapshot.items
            state.changeCount += 1
            state.restores += 1
            state.onRead = nil
            return true
        }
    }
}

/// Answers from a script: the focused element per pid, and the report an insertion produces.
final class FakeAccessibility: AccessibilityFacade {
    private struct State {
        var trusted = true
        var secureInput = false
        var elements: [Int32: FocusedElement] = [:]
        var report = AXInsertionReport.refused
        var insertions: [(text: String, pid: Int32)] = []
        var before: [Int32: Character] = [:]
        var selected: [Int32: String] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var insertions: [(text: String, pid: Int32)] { state.withLock { $0.insertions } }

    func set(trusted: Bool) { state.withLock { $0.trusted = trusted } }
    func set(secureInput: Bool) { state.withLock { $0.secureInput = secureInput } }
    func set(element: FocusedElement?, for pid: Int32) { state.withLock { $0.elements[pid] = element } }
    func set(report: AXInsertionReport) { state.withLock { $0.report = report } }
    /// What the field says sits before the caret. Unset means the app does not answer.
    func set(characterBeforeInsertion: Character?, for pid: Int32) {
        state.withLock { $0.before[pid] = characterBeforeInsertion }
    }

    /// What the focused element says is selected. Unset means the app does not answer.
    func set(selectedText: String?, for pid: Int32) { state.withLock { $0.selected[pid] = selectedText } }

    func isTrusted() async -> Bool { state.withLock { $0.trusted } }
    func focusedElement(of pid: Int32) async -> FocusedElement? { state.withLock { $0.elements[pid] } }
    func isSecureInputEnabled() async -> Bool { state.withLock { $0.secureInput } }

    func insertSelectedText(_ text: String, into pid: Int32) async -> AXInsertionReport {
        state.withLock { state in
            state.insertions.append((text, pid))
            return state.report
        }
    }

    func characterBeforeInsertion(of pid: Int32) async -> Character? { state.withLock { $0.before[pid] } }
    func selectedText(of pid: Int32) async -> String? { state.withLock { $0.selected[pid] } }
}

/// Polls until `condition` holds, for work a detached task finishes; gives up after about two seconds.
func eventually(_ condition: () -> Bool) async {
    for _ in 0..<2_000 where !condition() {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Records chords instead of posting them. `accepts` false is a system that drops them. `target` stands for the
/// focused app: it reads the pasteboard when ⌘V arrives, unless the test says nobody is there.
final class FakeKeystrokes: KeystrokeSynthesizer {
    private struct State {
        var accepts = true
        var posted: [KeyChord] = []
        var target: FakePasteboard?
        /// What the focused app copies when ⌘C arrives; nil is nothing selected.
        var selection: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(target: FakePasteboard? = nil) {
        state.withLock { $0.target = target }
    }

    var posted: [KeyChord] { state.withLock { $0.posted } }

    func set(accepts: Bool) { state.withLock { $0.accepts = accepts } }

    /// Nothing takes the paste: an unfocused web page, a hung app.
    func noAppReads() { state.withLock { $0.target = nil } }

    /// Text selected in the focused app, which a ⌘C puts on the pasteboard.
    func select(_ text: String?) { state.withLock { $0.selection = text } }

    func post(_ chord: KeyChord) async -> Bool {
        let (accepted, target, copied) = state.withLock { state -> (Bool, FakePasteboard?, String?) in
            guard state.accepts else { return (false, nil, nil) }
            state.posted.append(chord)
            return (true, state.target, chord == .copy ? state.selection : nil)
        }
        if chord == .paste { target?.appReads() }
        if let copied { target?.userCopies(copied) }
        return accepted
    }
}

/// A frontmost app that a test can switch, to stand for the user moving focus mid-utterance. It records the
/// applications it is asked to open, and brings them to the front unless told otherwise.
final class SwitchableWorkspace: Workspace {
    private let current: OSAllocatedUnfairLock<AppIdentity?>
    private let openings = OSAllocatedUnfairLock(initialState: (result: ApplicationOpening.frontmost, opened: [URL]()))

    init(_ app: AppIdentity?) {
        current = OSAllocatedUnfairLock(initialState: app)
    }

    func switchTo(_ app: AppIdentity?) { current.withLock { $0 = app } }
    func refuseToOpen() { openings.withLock { $0.result = .refused } }
    func openBehind() { openings.withLock { $0.result = .behind } }
    func exitAtOnce() { openings.withLock { $0.result = .exited } }
    var opened: [URL] { openings.withLock { $0.opened } }

    func frontmostApplication() async -> AppIdentity? { current.withLock { $0 } }
    func activate(_ app: AppIdentity) async -> Bool { true }

    func openApplication(at url: URL) async -> ApplicationOpening {
        openings.withLock { state in
            if state.result != .refused { state.opened.append(url) }
            return state.result
        }
    }
}

/// A focus probe that answers only when the test says so, to stand for an app slow to answer Accessibility.
final class GatedFocusProbe: FocusProbing {
    private let snapshot: FocusSnapshot
    private let gate = OSAllocatedUnfairLock(initialState: (open: false, waiters: [CheckedContinuation<Void, Never>]()))

    init(_ snapshot: FocusSnapshot) {
        self.snapshot = snapshot
    }

    func open() {
        let waiters = gate.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func probe() async -> FocusSnapshot {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = gate.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
        return snapshot
    }
}
