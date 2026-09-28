import ApplicationServices
import Foundation

public enum AccessibilityPermission {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt if not trusted yet; returns the current trust state. A grant made in System Settings
    /// lands later, so callers poll `isTrusted` to pick it up.
    @discardableResult
    public static func requestWithPrompt() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
