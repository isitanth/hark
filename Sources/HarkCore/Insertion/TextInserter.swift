import Foundation
import os

/// Puts dictated text where the user's caret is, by Accessibility or by paste, and gives the pasteboard back.
///
/// An AX insertion is checked by reading the field back; when the field shows the text is not there, it is pasted
/// instead, and when the app timed out it goes to the clipboard, since the app may still apply it.
///
/// A paste borrows the general pasteboard: the user's contents are snapshotted, the text goes on as a promise with the
/// transient marker so clipboard managers skip it, and ⌘V is posted for the current layout. The promise tells when an
/// app reads it. Only then is the paste counted, and `restoreDelay` later the snapshot goes back — unless something
/// else has written to the pasteboard since, which is then the user's to keep. When nothing reads it within
/// `readDeadline`, the paste landed nowhere: the text stays on the clipboard instead of the user's old contents
/// coming back over it.
///
/// An actor because the pending restore outlives the call: the pipeline is idle again while it waits, so a second
/// paste can arrive first. That one reuses the original snapshot rather than taking one of the first paste's text.
public actor TextInserter: TextInserting {
    /// After the first read. An app may read again, and a clipboard manager that ignores the transient marker can be
    /// the first reader; this keeps the text in place for the target either way.
    public static let defaultRestoreDelay: Duration = .milliseconds(500)
    /// An app reads the pasteboard when it handles ⌘V on its main thread, in milliseconds. A second without a read
    /// means no app is going to.
    public static let defaultReadDeadline: Duration = .seconds(1)
    /// How long a ⌘C gets to land on the pasteboard. In M9.0 it landed well inside this, osascript's own launch
    /// included. With nothing selected it never lands, and this is what the Ask key waits before it says so.
    public static let defaultCopyDeadline: Duration = .milliseconds(250)
    private static let copyPoll: Duration = .milliseconds(10)

    private struct PendingRestore {
        let original: PasteboardSnapshot
        /// The change count our own write left. Anything else on the pasteboard is not ours to overwrite.
        let written: Int
        let timer: Task<Void, Never>
    }

    private let accessibility: any AccessibilityFacade
    private let pasteboard: any PasteboardFacade
    private let keystrokes: any KeystrokeSynthesizer
    private let workspace: any Workspace
    private let clock: any Clock<Duration>
    private let restoreDelay: Duration
    private let readDeadline: Duration
    private let copyDeadline: Duration
    private var pending: PendingRestore?

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "insertion")

    public init(
        accessibility: any AccessibilityFacade,
        pasteboard: any PasteboardFacade,
        keystrokes: any KeystrokeSynthesizer,
        workspace: any Workspace,
        clock: any Clock<Duration> = ContinuousClock(),
        restoreDelay: Duration = TextInserter.defaultRestoreDelay,
        readDeadline: Duration = TextInserter.defaultReadDeadline,
        copyDeadline: Duration = TextInserter.defaultCopyDeadline
    ) {
        self.accessibility = accessibility
        self.pasteboard = pasteboard
        self.keystrokes = keystrokes
        self.workspace = workspace
        self.clock = clock
        self.restoreDelay = restoreDelay
        self.readDeadline = readDeadline
        self.copyDeadline = copyDeadline
    }

    /// Trailing line breaks would send the message in a chat app or run the line in a terminal.
    public static func prepared(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isNewline { text.removeLast() }
        return text
    }

    public func insert(
        _ text: String, plan: InsertionPlan, focus: FocusSnapshot?, clipboardFallback: Bool
    ) async throws(PipelineFailure) {
        let text = Self.prepared(text)
        guard !text.isEmpty else { return }
        guard let target = focus?.app else { throw .insertionFailed }

        // What the field already holds decides whether this dictation starts a new word. Read before the frontmost
        // check, not after: every message to a busy app costs time, and the check has to be the last thing that
        // happens before the text is sent, or it stops being the guarantee it was written to be.
        let spaced = InsertionSpacing.spaced(
            text, after: await accessibility.characterBeforeInsertion(of: target.processID))

        // The caret the text is meant for is in the app the trigger went down in. Anywhere else, it would land in a
        // window the user moved to after speaking.
        guard await workspace.frontmostApplication()?.processID == target.processID else {
            Self.logger.info("focus left \(target.logName, privacy: .public) before insertion")
            throw .focusChanged
        }

        switch plan {
        case .axInsert:
            let verdict = await accessibility.insertSelectedText(spaced, into: target.processID).verdict(for: spaced)
            Self.logger.info(
                "ax insert into \(target.logName, privacy: .public): \(verdict.rawValue, privacy: .public)")
            switch verdict {
            case .confirmed, .unverified: return
            case .uncertain: throw .insertionTimedOut
            case .absent:
                try await paste(spaced, into: target, concealed: false, clipboardFallback: clipboardFallback)
            }
        case .paste:
            try await paste(
                spaced, into: target, concealed: focus?.isSecureInput ?? false,
                clipboardFallback: clipboardFallback)
        }
    }

    private func paste(
        _ text: String, into target: AppIdentity, concealed: Bool, clipboardFallback: Bool
    ) async throws(PipelineFailure) {
        // Without trust the system drops posted events without a word, and the text would be lost at the restore.
        guard await accessibility.isTrusted() else {
            Self.logger.error("no Accessibility trust; nothing was pasted into \(target.logName, privacy: .public)")
            throw .insertionFailed
        }

        let original = await originalContents()
        pending?.timer.cancel()
        pending = nil

        var markers: Set<String> = [PasteboardMarker.transient]
        if concealed { markers.insert(PasteboardMarker.concealed) }
        let read = ReadSignal()
        guard let written = await pasteboard.promise(text, markers: markers, onRead: read.fire) else {
            Self.logger.error("the pasteboard refused the text for \(target.logName, privacy: .public)")
            throw .pasteboardWrite
        }

        guard await keystrokes.post(.paste) else {
            _ = await pasteboard.restore(original, ifChangeCountIs: written)
            Self.logger.error("⌘V was not posted for \(target.logName, privacy: .public)")
            throw .insertionFailed
        }
        guard await read.wait(upTo: readDeadline, on: clock) else {
            // The paste landed nowhere. With the fallback on, the text stays on the clipboard for the user to
            // paste themselves, which is why it is not restored here. With it off, nothing is going to keep this
            // text — and the pasteboard was only borrowed, so it goes back rather than being left holding a
            // dictation the log is about to record as discarded.
            if !clipboardFallback {
                _ = await pasteboard.restore(original, ifChangeCountIs: written)
                Self.logger.error(
                    "nothing read the paste into \(target.logName, privacy: .public); the clipboard was put back")
            } else {
                Self.logger.info("nothing read the paste into \(target.logName, privacy: .public)")
            }
            throw .pasteNotConsumed
        }
        Self.logger.info("pasted into \(target.logName, privacy: .public)")

        let timer = Task { [clock, restoreDelay] in
            do {
                try await clock.sleep(for: restoreDelay)
            } catch {
                return
            }
            await self.restore(after: written)
        }
        pending = PendingRestore(original: original, written: written, timer: timer)
    }

    /// The selection of `target`, copied with ⌘C, and the pasteboard given back at once. The Ask key's read where the
    /// Accessibility API says nothing (web page text, Mail, Chromium and Electron apps; M9.0). Nil when nothing was
    /// copied within `copyDeadline`, which is what happens with nothing selected.
    ///
    /// Here rather than beside the Accessibility read because a paste's restore may still be pending: the user's
    /// contents are then that restore's snapshot, not the dictation on the pasteboard, and they are what goes back.
    public func copySelection(from target: AppIdentity) async -> String? {
        guard await accessibility.isTrusted(),
            await workspace.frontmostApplication()?.processID == target.processID
        else { return nil }
        let original = await originalContents()
        pending?.timer.cancel()
        pending = nil

        let before = await pasteboard.changeCount()
        var copied: String?
        if await keystrokes.post(.copy) {
            // An app clears the pasteboard, then writes: the count moves before the text is there.
            let polls = Int(copyDeadline / Self.copyPoll)
            for poll in 0...polls {
                if await pasteboard.changeCount() != before, let text = await pasteboard.snapshot().plainText {
                    copied = text
                    break
                }
                if poll < polls { try? await clock.sleep(for: Self.copyPoll) }
            }
        }
        let now = await pasteboard.changeCount()
        if now != original.changeCount, !(await pasteboard.restore(original, ifChangeCountIs: now)) {
            Self.logger.info("pasteboard changed during the copy; left as it is")
        }
        Self.logger.info(
            "copied the selection of \(target.logName, privacy: .public): \(copied == nil ? "nothing" : "text", privacy: .public)"
        )
        return copied
    }

    /// The user's own contents. While a restore is pending and nothing else has written, the pasteboard still holds
    /// the previous paste's text, and the snapshot that restore would have put back is the one to keep.
    private func originalContents() async -> PasteboardSnapshot {
        if let pending, await pasteboard.changeCount() == pending.written {
            return pending.original
        }
        return await pasteboard.snapshot()
    }

    private func restore(after written: Int) async {
        guard let pending, pending.written == written else { return }
        self.pending = nil
        if !(await pasteboard.restore(pending.original, ifChangeCountIs: written)) {
            Self.logger.info("pasteboard changed since the paste; left as it is")
        }
    }
}

/// Fired by the pasteboard promise when an app reads it; waited on, with a deadline, by the paste.
private final class ReadSignal: Sendable {
    private struct State {
        var read = false
        var over = false
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    @Sendable func fire() {
        settle { $0.read = true }
    }

    /// True once an app has read the promise, false when `deadline` passes first. No timer starts when the read has
    /// already happened, which is the usual case: the app reads while ⌘V is being handled.
    func wait(upTo deadline: Duration, on clock: any Clock<Duration>) async -> Bool {
        if state.withLock({ $0.read }) { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let answer = self.state.withLock { state -> Bool? in
                        if state.read || state.over { return state.read }
                        state.waiter = continuation
                        return nil
                    }
                    if let answer { continuation.resume(returning: answer) }
                }
            }
            group.addTask {
                try? await clock.sleep(for: deadline)
                return false
            }
            let first = await group.next() ?? false
            // Ends whichever child is still waiting: the sleep by cancellation, the continuation by settling it.
            group.cancelAll()
            settle { $0.over = true }
            return first
        }
    }

    private func settle(_ change: @Sendable (inout State) -> Void) {
        let (waiter, read) = state.withLock { state -> (CheckedContinuation<Bool, Never>?, Bool) in
            change(&state)
            defer { state.waiter = nil }
            return (state.read || state.over ? state.waiter : nil, state.read)
        }
        waiter?.resume(returning: read)
    }
}
