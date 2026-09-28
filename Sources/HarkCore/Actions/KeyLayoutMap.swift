import Carbon.HIToolbox
import Foundation

/// What each virtual key code types on one keyboard layout, so a `KeyChord` named by character finds its key on
/// QWERTY, AZERTY and Dvorak alike.
public struct KeyLayoutMap: Sendable, Equatable {
    /// Virtual key code -> what it types with no modifier, and with Command held.
    public let plain: [UInt16: String]
    public let command: [UInt16: String]

    public init(plain: [UInt16: String], command: [UInt16: String]) {
        self.plain = plain
        self.command = command
    }

    /// The key code that types `character` under `modifiers`. Only `.command` selects the command table; when several
    /// codes type it, the lowest wins, so the main row beats the keypad.
    public func keyCode(for character: Character, modifiers: KeyModifiers) -> UInt16? {
        let table = modifiers.contains(.command) ? command : plain
        let wanted = String(character).lowercased()
        return table.filter { $0.value.lowercased() == wanted }.keys.min()
    }

    /// Where an ANSI (US QWERTY) keyboard has the letter or digit: the fallback when a layout has no key for it.
    public static func ansiKeyCode(for character: Character) -> UInt16? {
        ansiCodes[Character(String(character).lowercased())]
    }

    private static let ansiCodes: [Character: UInt16] = {
        let codes: [(Character, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9),
        ]
        return Dictionary(uniqueKeysWithValues: codes.map { ($0.0, UInt16($0.1)) })
    }()

    /// Builds the map by asking UCKeyTranslate what each key code 0..<128 types, with no modifier and with Command.
    /// Dead keys are read as the character they print on their own (the mask, not the bit index: with the index the
    /// option is 0, dead keys start a sequence and type nothing, and AZERTY's ^ and ` drop out of the map).
    public static func translating(layoutData: Data, keyboardType: UInt32) -> KeyLayoutMap {
        layoutData.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return KeyLayoutMap(plain: [:], command: [:])
            }
            return KeyLayoutMap(
                plain: table(layout, modifiers: 0, keyboardType: keyboardType),
                command: table(layout, modifiers: UInt32(cmdKey), keyboardType: keyboardType))
        }
    }

    private static func table(
        _ layout: UnsafePointer<UCKeyboardLayout>, modifiers: UInt32, keyboardType: UInt32
    ) -> [UInt16: String] {
        var result: [UInt16: String] = [:]
        for code in UInt16(0)..<128 {
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDown), (modifiers >> 8) & 0xFF, keyboardType,
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            if status == noErr && length > 0 {
                result[code] = String(utf16CodeUnits: chars, count: length)
            }
        }
        return result
    }

    /// The keyboard layout in use. Main actor: Text Input Source calls are main-thread API inside an app.
    @MainActor public static func current() -> KeyLayoutMap? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return map(for: source)
    }

    /// An installed layout by input source ID (for example "com.apple.keylayout.French"), enabled or not. For tests.
    @MainActor public static func installed(_ inputSourceID: String) -> KeyLayoutMap? {
        let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
            let source = sources.first
        else { return nil }
        return map(for: source)
    }

    @MainActor private static func map(for source: TISInputSource) -> KeyLayoutMap? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return translating(layoutData: data, keyboardType: UInt32(LMGetKbdType()))
    }
}
