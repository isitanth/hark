import ApplicationServices
import CoreGraphics
import HarkCore
import os

/// Posts key chords as CGEvents. Explicitly on the main actor, because the layout lookup behind a character is a
/// Text Input Source call.
///
/// The source and tap are the ones clipboard managers such as Maccy use for their paste, which is known to reach
/// every kind of app: the combined session state, local keyboard events suppressed around the post so a key the
/// user still holds does not mix in, and the session event tap.
@MainActor
final class CGEventKeystrokeSynthesizer: KeystrokeSynthesizer {
    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "keystrokes")

    func post(_ chord: KeyChord) async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let code = keyCode(for: chord.key, modifiers: chord.modifiers) else {
            Self.logger.error("no key types \(String(describing: chord.key), privacy: .public) on this layout")
            return false
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return false }
        let flags = Self.flags(chord.modifiers)
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    private func keyCode(for key: KeyChord.Key, modifiers: KeyModifiers) -> CGKeyCode? {
        switch key {
        case .code(let code):
            return code
        case .character(let character):
            // The layout's own key first: on Dvorak "v" is where QWERTY has ".", except under ⌘ on the Dvorak -
            // QWERTY ⌘ layout. The ANSI position is the fallback for a layout that cannot type the character at all.
            return KeyLayoutMap.current()?.keyCode(for: character, modifiers: modifiers)
                ?? KeyLayoutMap.ansiKeyCode(for: character)
        }
    }

    /// The device-independent masks, plus the left-hand device bits, which some apps check to tell a real ⌘ from a
    /// flag with no key behind it (IOKit's NX_DEVICELCMDKEYMASK and its siblings).
    private static func flags(_ modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.formUnion([.maskCommand, CGEventFlags(rawValue: 0x08)]) }
        if modifiers.contains(.shift) { flags.formUnion([.maskShift, CGEventFlags(rawValue: 0x02)]) }
        if modifiers.contains(.option) { flags.formUnion([.maskAlternate, CGEventFlags(rawValue: 0x20)]) }
        if modifiers.contains(.control) { flags.formUnion([.maskControl, CGEventFlags(rawValue: 0x01)]) }
        return flags
    }
}
