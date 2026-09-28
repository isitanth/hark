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
        return lines(liveSelection) == lines(selection.text) ? .intact : .changed
    }

    /// The Services pasteboard and the Accessibility API need not agree on line endings.
    private static func lines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
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

    private let workspace: any Workspace
    private let focus: any FocusProbing
    private let accessibility: (any AccessibilityFacade)?
    private let settings: ResolutionSettings

    public init(
        workspace: any Workspace, focus: any FocusProbing, accessibility: (any AccessibilityFacade)?,
        settings: ResolutionSettings
    ) {
        self.workspace = workspace
        self.focus = focus
        self.accessibility = accessibility
        self.settings = settings
    }

    public func check(_ selection: SelectionSnapshot) async -> SelectionCheck {
        if let caller = selection.caller {
            _ = await workspace.activateAndWait(caller, timeout: Self.activationTimeout)
        }
        let now = await focus.probe()
        var live: String?
        if let pid = now.app?.processID, pid == selection.caller?.processID {
            live = await accessibility?.selectedText(of: pid)
        }
        let verdict = SelectionGuard.verdict(selection, frontmost: now.app, liveSelection: live)
        let plan = verdict == .intact ? FocusResolver.pastePlan(focus: now, apps: settings.current.apps) : nil
        return SelectionCheck(verdict: verdict, focus: now, plan: plan)
    }
}
