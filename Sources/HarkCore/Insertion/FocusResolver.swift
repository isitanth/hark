import Foundation

/// What the focused element is, as far as the Accessibility API can tell.
public enum FocusKind: Sendable, Equatable, CaseIterable {
    case text
    case notText
    /// No element, or an element without a role: nothing focused, no Accessibility trust, or an app that hides its tree.
    case unknown
}

/// Decides how a transcript reaches the user: AX insertion, paste, or the clipboard.
public enum FocusResolver {
    /// Roles that are text whatever else they say.
    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Apps whose Accessibility answers cannot be trusted for text, so they always get paste unless `apps:` says
    /// otherwise. Bundle IDs, lowercase.
    public static let alwaysPaste: Set<String> = [
        // Terminals
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
        // Chromium browsers
        "com.google.chrome", "com.google.chrome.canary", "com.brave.browser", "com.microsoft.edgemac",
        "company.thebrowser.browser", "company.thebrowser.dia", "com.vivaldi.vivaldi", "com.operasoftware.opera",
        "org.chromium.chromium",
        // Firefox
        "org.mozilla.firefox", "org.torproject.torbrowser",
        // Electron, also caught by embedsChromium, listed so a bundle-ID check alone works
        "com.tinyspeck.slackmacgap", "com.microsoft.vscode", "com.microsoft.vscodeinsiders",
        "com.todesktop.230313mzl4w4u92", "notion.id", "com.hnc.discord", "com.anthropic.claudefordesktop",
    ]

    /// JetBrains IDEs answer through Java accessibility.
    public static let alwaysPastePrefixes: [String] = ["com.jetbrains."]

    public static func kind(of element: FocusedElement?) -> FocusKind {
        guard let element, let role = element.role else { return .unknown }
        return element.acceptsSelectedText || textRoles.contains(role) ? .text : .notText
    }

    public static func needsPaste(_ app: AppIdentity?) -> Bool {
        guard let app else { return false }
        if app.embedsChromium { return true }
        guard let bundleID = app.bundleID?.lowercased() else { return false }
        return alwaysPaste.contains(bundleID) || alwaysPastePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// The mode in force for `app`: its `apps:` entry if there is one (bundle ID compared case-insensitively), else
    /// `global`.
    public static func mode(
        for app: AppIdentity?, global: InsertionMode, apps: [String: AppOverride]
    ) -> (mode: InsertionMode, overridden: Bool) {
        guard let bundleID = app?.bundleID?.lowercased() else { return (global, false) }
        let entry = apps[bundleID] ?? apps.first { $0.key.lowercased() == bundleID }?.value
        guard let entry else { return (global, false) }
        return (entry.insert, true)
    }

    /// `clipboardFallback` off discards text that has nowhere to go instead of copying it. A copy the user asked
    /// for — clipboard-only mode, or an `apps:` entry that says clipboard — is the destination, not a fallback, and
    /// happens either way.
    public static func decide(
        focus: FocusSnapshot?, global: InsertionMode, apps: [String: AppOverride], clipboardFallback: Bool = true
    ) -> Decision {
        let (mode, overridden) = mode(for: focus?.app, global: global, apps: apps)
        if mode == .clipboard { return .copy(.chosen) }
        guard let focus, !focus.isSecureInput,
            let plan = plan(focus: focus, mode: mode, overridden: overridden)
        else {
            let reason: ClipboardReason = focus?.isSecureInput == true ? .secureField : .noTextField
            return clipboardFallback ? .copy(reason) : .discard(.clipboardFallbackDisabled)
        }
        return .insert(plan, fallback: clipboardFallback)
    }

    /// Where the panel's Paste button puts the text. The user has already asked for it to go into the field, so
    /// clipboard-only mode — global or from an `apps:` entry — is not one of the answers; it says where *dictation*
    /// goes. A password field still takes nothing. Nil when there is nowhere to put it.
    public static func pastePlan(focus: FocusSnapshot?, apps: [String: AppOverride] = [:]) -> InsertionPlan? {
        guard let focus, !focus.isSecureInput else { return nil }
        let (mode, overridden) = mode(for: focus.app, global: .accessibility, apps: apps)
        guard mode != .clipboard else { return plan(focus: focus, mode: .accessibility, overridden: false) }
        return plan(focus: focus, mode: mode, overridden: overridden)
    }

    /// How the text would be delivered into `focus`, or nil when nothing there takes text. `mode` is the one in
    /// force and is never `.clipboard`.
    private static func plan(focus: FocusSnapshot, mode: InsertionMode, overridden: Bool) -> InsertionPlan? {
        let kind = kind(of: focus.element)

        // Chromium and Electron answer "no focused element" while their AX tree is off, so unknown there is most
        // likely a web text field. An explicit apps: paste is the user saying AX lies in that app.
        if (mode == .paste && overridden) || (!overridden && needsPaste(focus.app)) {
            return kind == .notText ? nil : .paste
        }
        // Unknown in a native app means nothing focused or no AX trust: a paste would land nowhere and the text
        // would be lost when the pasteboard is restored.
        guard kind == .text else { return nil }
        if mode == .accessibility, focus.element?.acceptsSelectedText == true { return .axInsert }
        return .paste
    }
}
