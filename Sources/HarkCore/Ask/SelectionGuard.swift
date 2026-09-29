import Foundation

/// What Replace found once the caller was brought back.
public enum SelectionVerdict: Sendable, Equatable {
    /// The caller is in front, and its selection is still the text asked about, or cannot be read (the app check
    /// alone).
    case intact
    /// Another app is in front, or the caller is not known.
    case otherApp
    /// The caller is in front and its selection is no longer the text asked about.
    case changed
}

/// Replace writes over the caller's selection, so it checks first that the selection is the one the ask was about.
public enum SelectionGuard {
    /// - Parameter liveSelection: the caller's selected text as the Accessibility API reads it now; nil when it does
    ///   not say, which leaves the app check alone.
    public static func verdict(
        _ selection: SelectionSnapshot, frontmost: AppIdentity?, liveSelection: String?
    ) -> SelectionVerdict {
        guard let caller = selection.caller, frontmost?.processID == caller.processID else { return .otherApp }
        guard let liveSelection else { return .intact }
        return comparable(liveSelection) == comparable(selection.text) ? .intact : .changed
    }

    /// The Services pasteboard, the Accessibility API and a ⌘C need not agree on line endings, non-breaking spaces or
    /// runs of white space, only on the words and their order.
    private static func comparable(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The verdict, where the focus now is, and how the answer would go in: nil when nothing there takes text.
public struct SelectionCheck: Sendable, Equatable {
    public var verdict: SelectionVerdict
    public var focus: FocusSnapshot
    public var plan: InsertionPlan?

    public init(verdict: SelectionVerdict, focus: FocusSnapshot, plan: InsertionPlan? = nil) {
        self.verdict = verdict
        self.focus = focus
        self.plan = plan
    }
}

/// Replace's first step, a seam so the reducer's tests script it. `CallerSelectionChecker` is the real one.
public protocol SelectionChecking: Sendable {
    func check(_ selection: SelectionSnapshot) async -> SelectionCheck
}

/// Brings the caller back, looks at its focused element, reads its selection, and decides as `SelectionGuard` says.
/// The plan is the panel Paste's: the user asked for this text in this field, so clipboard-only mode does not apply.
public struct CallerSelectionChecker: SelectionChecking {
    /// As long as the panel's Paste waits for an app that is slow to come forward.
    public static let activationTimeout = Duration.seconds(2)
    /// The Ask panel was key a moment ago and may still be: until the caller's window is key again, a web view answers
    /// "no focused element" (Safari, measured 2026-09-28), which would read as nothing to write into.
    public static let focusSettle = Duration.milliseconds(600)
    public static let focusPoll = Duration.milliseconds(30)

    private let workspace: any Workspace
    private let focus: any FocusProbing
    private let accessibility: (any AccessibilityFacade)?
    private let copier: (any SelectionCopying)?
    private let settings: ResolutionSettings
    private let settle: Duration
    private let poll: Duration

    /// `copier` reads the selection with ⌘C where the Accessibility API says nothing, as the Ask key's read does; nil
    /// leaves the app check alone there.
    public init(
        workspace: any Workspace, focus: any FocusProbing, accessibility: (any AccessibilityFacade)?,
        copier: (any SelectionCopying)? = nil, settings: ResolutionSettings, settle: Duration = focusSettle,
        poll: Duration = focusPoll
    ) {
        self.workspace = workspace
        self.focus = focus
        self.accessibility = accessibility
        self.copier = copier
        self.settings = settings
        self.settle = settle
        self.poll = poll
    }

    public func check(_ selection: SelectionSnapshot) async -> SelectionCheck {
        if let caller = selection.caller {
            _ = await workspace.activateAndWait(caller, timeout: Self.activationTimeout)
        }
        let now = await settledFocus(of: selection.caller)
        var live: String?
        if let app = now.app, app.processID == selection.caller?.processID {
            live = await accessibility?.selectedText(of: app.processID)
            // Dia, Claude, web text (M9.0): read the way the press read it, or text selected since the press would be
            // written over unseen. Nothing copied is nothing selected.
            if live == nil, let copier, !now.isSecureInput, !SelectionReader.copiesLine(app) {
                live = await copier.copySelection(from: app) ?? ""
            }
        }
        let verdict = SelectionGuard.verdict(selection, frontmost: now.app, liveSelection: live)
        let plan = verdict == .intact ? FocusResolver.pastePlan(focus: now, apps: settings.current.apps) : nil
        return SelectionCheck(verdict: verdict, focus: now, plan: plan)
    }

    /// The focus once the caller holds one: probed again while the caller is in front with no focused element, for
    /// `settle` at most. Another app in front, or an element found, answers at once.
    private func settledFocus(of caller: AppIdentity?) async -> FocusSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now + settle
        var now = await focus.probe()
        while now.element == nil, let caller, now.app?.processID == caller.processID, clock.now < deadline {
            try? await clock.sleep(for: poll)
            now = await focus.probe()
        }
        return now
    }
}
