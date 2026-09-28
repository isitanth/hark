import Foundation

/// A ⌘C of the front app's selection, with the pasteboard given back. `TextInserter` implements it.
public protocol SelectionCopying: Sendable {
    func copySelection(from target: AppIdentity) async -> String?
}

extension TextInserter: SelectionCopying {}

/// What the Ask key reads at the press, before the Ask panel takes the keyboard (M9.0).
///
/// The Accessibility read comes first. It answers at once in native and web text fields, and it costs nothing. An
/// empty answer is a caret, so nothing is selected and there is no ⌘C. Only where the read says nothing at all (web
/// page text, Mail, and Chromium or Electron apps with their tree off) does a ⌘C go out, never into secure input. The
/// text stays in memory for the ask and is never logged.
public struct SelectionReader: Sendable {
    private let accessibility: any AccessibilityFacade
    private let copier: any SelectionCopying

    public init(accessibility: any AccessibilityFacade, copier: any SelectionCopying) {
        self.accessibility = accessibility
        self.copier = copier
    }

    /// The selection in `app`, blank when there is none or no app is known.
    public func read(from app: AppIdentity?) async -> SelectionSnapshot {
        guard let app else { return SelectionSnapshot(text: "", caller: nil) }
        if let text = await accessibility.selectedText(of: app.processID) {
            return SelectionSnapshot(text: text, caller: app)
        }
        guard !(await accessibility.isSecureInputEnabled()) else { return SelectionSnapshot(text: "", caller: app) }
        return SelectionSnapshot(text: await copier.copySelection(from: app) ?? "", caller: app)
    }
}
