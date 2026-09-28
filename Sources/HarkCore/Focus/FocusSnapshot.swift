import Foundation

public struct AppIdentity: Sendable, Equatable {
    public var bundleID: String?
    public var name: String?
    public var processID: Int32
    /// The app ships its own Chromium (Electron, CEF). Its text fields answer the Accessibility API only once an
    /// assistive app switches its tree on, and even then an AX insertion is ignored or half applied, so it gets paste.
    public var embedsChromium: Bool

    public init(bundleID: String?, name: String?, processID: Int32, embedsChromium: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.processID = processID
        self.embedsChromium = embedsChromium
    }

    /// The value written to the log's `target_app` key.
    public var logName: String {
        bundleID ?? name ?? "pid:\(processID)"
    }

    /// The frameworks that mark an app bundle as embedding Chromium, under `Contents/Frameworks`.
    public static let chromiumFrameworks = ["Electron Framework.framework", "Chromium Embedded Framework.framework"]

    /// Whether the bundle at `bundleURL` embeds Chromium. `exists` is `FileManager.fileExists(atPath:)` outside tests.
    public static func embedsChromium(bundleURL: URL, exists: (String) -> Bool) -> Bool {
        let frameworks = bundleURL.appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
        return chromiumFrameworks.contains {
            exists(frameworks.appending(path: $0, directoryHint: .isDirectory).path(percentEncoded: false))
        }
    }
}

/// What the Accessibility API said about the focused element when the trigger went down. The strings are the raw
/// `kAXRoleAttribute` and `kAXSubroleAttribute` values; nil is an attribute the app did not answer.
public struct FocusedElement: Sendable, Equatable {
    public var role: String?
    public var subrole: String?
    /// `kAXSelectedTextAttribute` is settable, so the element can take an AX insertion.
    public var acceptsSelectedText: Bool
    /// `kAXValueAttribute` is settable. A text element that says no to both still takes a paste.
    public var valueSettable: Bool

    public init(role: String?, subrole: String? = nil, acceptsSelectedText: Bool = false, valueSettable: Bool = false) {
        self.role = role
        self.subrole = subrole
        self.acceptsSelectedText = acceptsSelectedText
        self.valueSettable = valueSettable
    }

    /// `kAXSecureTextFieldSubrole`, spelled out so HarkCore's pure types need no ApplicationServices.
    public static let secureTextFieldSubrole = "AXSecureTextField"
}

/// Where the user was when the trigger went down.
public struct FocusSnapshot: Sendable, Equatable {
    public var app: AppIdentity?
    /// Nil when there was no answer: no Accessibility trust, no focused element, or the app timed out.
    public var element: FocusedElement?
    /// A password field has focus, or some app holds secure event input. The text goes to the clipboard, marked
    /// concealed, and the log writes `raw_text` and `normalized_text` as null.
    public var isSecureInput: Bool

    public init(app: AppIdentity?, element: FocusedElement? = nil, isSecureInput: Bool = false) {
        self.app = app
        self.element = element
        self.isSecureInput = isSecureInput
    }
}

/// How `TextInserter` delivers the text. `axInsert` falls back to `paste` when reading the field back shows the
/// text is not there.
public enum InsertionPlan: Sendable, Equatable {
    case axInsert
    case paste
}
