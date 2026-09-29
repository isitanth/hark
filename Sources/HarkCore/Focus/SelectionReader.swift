import Foundation

/// A ⌘C of the front app's selection, with the pasteboard given back. `TextInserter` implements it.
public protocol SelectionCopying: Sendable {
    func copySelection(from target: AppIdentity) async -> String?
}

extension TextInserter: SelectionCopying {}

/// Where an ask's selection is read: the Ask key's press, and a spoken prefix once its words are resolved.
public protocol SelectionReading: Sendable {
    func read(from app: AppIdentity?) async -> SelectionSnapshot
}

/// What the Ask key reads at the press, before the Ask panel takes the keyboard (M9.0).
///
/// The Accessibility read comes first. It answers at once in native and web text fields, and it costs nothing. An
/// empty answer is a caret, so nothing is selected and there is no ⌘C. Only where the read says nothing at all (web
/// page text, Mail, and Chromium or Electron apps with their tree off) does a ⌘C go out, never into secure input. The
/// text stays in memory for the ask and is never logged.
public struct SelectionReader: SelectionReading {
    private let accessibility: any AccessibilityFacade
    private let copier: any SelectionCopying

    public init(accessibility: any AccessibilityFacade, copier: any SelectionCopying) {
        self.accessibility = accessibility
        self.copier = copier
    }

    /// Editors whose ⌘C copies the current line when nothing is selected: there a copy would turn a question into an
    /// ask about a line of code. Bundle IDs, lowercase; JetBrains IDEs by prefix.
    public static let copiesLineWithoutSelection: Set<String> = [
        "com.microsoft.vscode", "com.microsoft.vscodeinsiders", "com.todesktop.230313mzl4w4u92",
        "com.sublimetext.4", "com.sublimetext.3",
    ]
    public static let copiesLineWithoutSelectionPrefixes = ["com.jetbrains."]

    /// The selection in `app`, blank when there is none or no app is known. Hark's own windows are never read.
    public func read(from app: AppIdentity?) async -> SelectionSnapshot {
        guard let app, app.processID != ProcessInfo.processInfo.processIdentifier else {
            return SelectionSnapshot(text: "", caller: nil)
        }
        if let text = await accessibility.selectedText(of: app.processID) {
            return SelectionSnapshot(text: text, caller: app)
        }
        guard !(await accessibility.isSecureInputEnabled()), !Self.copiesLine(app) else {
            return SelectionSnapshot(text: "", caller: app)
        }
        return SelectionSnapshot(text: await copier.copySelection(from: app) ?? "", caller: app)
    }

    static func copiesLine(_ app: AppIdentity) -> Bool {
        guard let id = app.bundleID?.lowercased() else { return false }
        return copiesLineWithoutSelection.contains(id)
            || copiesLineWithoutSelectionPrefixes.contains { id.hasPrefix($0) }
    }
}
