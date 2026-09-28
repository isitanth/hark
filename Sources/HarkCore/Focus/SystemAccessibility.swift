import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// The Accessibility API. Every call is IPC to the target app and blocks until it answers or the messaging timeout
/// passes, so the calls run on one serial queue of their own rather than on the cooperative pool.
public struct SystemAccessibility: AccessibilityFacade {
    /// Seconds an app gets to answer one message. An app that is busy or hung costs at most this per attribute.
    public static let messagingTimeout: Float = 0.25

    private static let queue = DispatchQueue(label: "com.anthonychambet.hark.accessibility", qos: .userInitiated)

    public init() {}

    public func isTrusted() async -> Bool {
        AXIsProcessTrusted()
    }

    public func isSecureInputEnabled() async -> Bool {
        IsSecureEventInputEnabled()
    }

    public func focusedElement(of pid: Int32) async -> FocusedElement? {
        await Self.run {
            guard let element = Self.focused(in: pid) else { return nil }
            return FocusedElement(
                role: Self.string(element, kAXRoleAttribute),
                subrole: Self.string(element, kAXSubroleAttribute),
                acceptsSelectedText: Self.isSettable(element, kAXSelectedTextAttribute),
                valueSettable: Self.isSettable(element, kAXValueAttribute))
        }
    }

    public func insertSelectedText(_ text: String, into pid: Int32) async -> AXInsertionReport {
        await Self.run {
            guard let element = Self.focused(in: pid) else { return .refused }
            let before = Self.textState(element)
            let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            let timedOut = status == .cannotComplete
            guard status == .success || timedOut else { return AXInsertionReport(setSucceeded: false, before: before) }
            let after = Self.textState(element)
            let readBack = before.selectionLocation.flatMap {
                Self.string(element, location: $0, length: text.utf16.count)
            }
            return AXInsertionReport(
                setSucceeded: status == .success, timedOut: timedOut, before: before, after: after, readBack: readBack)
        }
    }

    /// UTF-16 units read back before the caret. One would cut a surrogate pair in half and two would cut a letter
    /// with combining marks or a flag emoji; eight covers any grapheme that is not decorative, at the same cost of
    /// one message. Only the last character of what comes back is used, so a fragment at the front is harmless.
    static let caretLookBehind = 8

    public func characterBeforeInsertion(of pid: Int32) async -> Character? {
        await Self.run {
            guard let element = Self.focused(in: pid) else { return nil }
            // Only the selection: the character count that `textState` also fetches would be a message wasted.
            guard let range = Self.copy(element, kAXSelectedTextRangeAttribute).flatMap(Self.cfRange) else {
                return nil
            }
            // A selection is replaced, not appended to, so what precedes it is not what the text continues from.
            guard range.length == 0, range.location > 0 else { return nil }
            let wanted = min(Self.caretLookBehind, range.location)
            return Self.string(element, location: range.location - wanted, length: wanted)?.last
        }
    }

    public func selectedText(of pid: Int32) async -> String? {
        await Self.run {
            guard let element = Self.focused(in: pid) else { return nil }
            return Self.string(element, kAXSelectedTextAttribute)
        }
    }

    // MARK: Internals

    private static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private static func focused(in pid: Int32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let value = copy(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        // Checked just above; the cast cannot fail.
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func textState(_ element: AXUIElement) -> AXTextState {
        let range = copy(element, kAXSelectedTextRangeAttribute).flatMap(cfRange)
        return AXTextState(
            selectionLocation: range?.location, selectionLength: range?.length,
            characterCount: copy(element, kAXNumberOfCharactersAttribute) as? Int)
    }

    private static func cfRange(_ value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // Checked just above; the cast cannot fail.
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func string(_ element: AXUIElement, location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
        return status == .success ? value as? String : nil
    }
}
