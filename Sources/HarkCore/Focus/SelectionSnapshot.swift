import Foundation

/// What Services › Ask Hark was called on: the selected text and the app it came from. The text lives in memory for
/// the length of the ask and is never logged: the description names its length only.
public struct SelectionSnapshot: Sendable, Equatable, CustomStringConvertible {
    public var text: String
    /// The app in front before Hark, `AppModel.previousApp`: inside a Services call the frontmost app is Hark itself.
    /// Nil when Hark saw no other app come forward since launch.
    public var caller: AppIdentity?

    public init(text: String, caller: AppIdentity?) {
        self.text = text
        self.caller = caller
    }

    /// Nothing but whitespace: the ask ends at once as `discarded(empty_selection)`, with no capture.
    public var isBlank: Bool {
        text.allSatisfy(\.isWhitespace)
    }

    public var description: String {
        "SelectionSnapshot(\(text.count) characters from \(caller?.logName ?? "unknown"))"
    }
}
