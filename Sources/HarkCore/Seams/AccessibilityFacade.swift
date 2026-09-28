import Foundation

/// A text element's selection and length, as the Accessibility API reports them: UTF-16 offsets, like `CFRange`.
public struct AXTextState: Sendable, Equatable {
    public var selectionLocation: Int?
    public var selectionLength: Int?
    public var characterCount: Int?

    public init(selectionLocation: Int? = nil, selectionLength: Int? = nil, characterCount: Int? = nil) {
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.characterCount = characterCount
    }

    public static let unknown = AXTextState()
}

/// What an AX insertion did, observed from the outside: the element before and after `kAXSelectedTextAttribute` was
/// set, and the text read back from where the selection began (`kAXStringForRangeParameterizedAttribute`).
public struct AXInsertionReport: Sendable, Equatable {
    /// The set call returned `kAXErrorSuccess`. Chromium says yes and does nothing, so this alone proves little.
    public var setSucceeded: Bool
    /// The set call ran out of messaging time (`kAXErrorCannotComplete`). The app may still apply it once it gets to
    /// the request, so this is neither a success nor a refusal.
    public var timedOut: Bool
    public var before: AXTextState
    public var after: AXTextState
    public var readBack: String?

    public init(
        setSucceeded: Bool, timedOut: Bool = false, before: AXTextState = .unknown, after: AXTextState = .unknown,
        readBack: String? = nil
    ) {
        self.setSucceeded = setSucceeded
        self.timedOut = timedOut
        self.before = before
        self.after = after
        self.readBack = readBack
    }

    /// No focused element, or it would not take the set.
    public static let refused = AXInsertionReport(setSucceeded: false)
}

/// ApplicationServices-backed. Calls are IPC to the target app, bounded by a 0.25 s messaging timeout each, so the
/// implementation runs them off the cooperative pool.
public protocol AccessibilityFacade: Sendable {
    /// `AXIsProcessTrusted()`. Without it every other call answers nothing, and posted key events are dropped.
    func isTrusted() async -> Bool
    /// Role, subrole and settable attributes of `pid`'s focused element, or nil when the app does not say.
    func focusedElement(of pid: Int32) async -> FocusedElement?
    /// `IsSecureEventInputEnabled()`: some app, usually a password field, is keeping keystrokes private.
    func isSecureInputEnabled() async -> Bool
    /// Replaces the selection in `pid`'s focused element with `text`, and reports what reading it back showed.
    func insertSelectedText(_ text: String, into pid: Int32) async -> AXInsertionReport
    /// The character dictated text would land right after in `pid`'s focused element. Nil at the start of a field,
    /// when text is selected — the insertion replaces it rather than continuing from it — and whenever the app does
    /// not answer, which is most of the ones that get a paste. `InsertionSpacing` reads nil as "change nothing".
    func characterBeforeInsertion(of pid: Int32) async -> Character?
    /// `kAXSelectedTextAttribute` of `pid`'s focused element: what Replace checks before it writes. Empty when there is
    /// only a caret; nil when the app does not say.
    func selectedText(of pid: Int32) async -> String?
}
