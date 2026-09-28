import Foundation

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

/// A key press named by what it types, not by where the key sits, so ⌘V is ⌘V on QWERTY, AZERTY and Dvorak alike.
/// `KeyLayoutMap` turns the character into a key code for the layout in use when it is posted.
public struct KeyChord: Sendable, Equatable {
    public enum Key: Sendable, Equatable {
        /// Resolved through the current layout.
        case character(Character)
        /// A virtual key code that types nothing and so sits in the same place on every layout (Return, Escape, F13).
        case code(UInt16)
    }

    public var key: Key
    public var modifiers: KeyModifiers

    public init(key: Key, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public static let paste = KeyChord(key: .character("v"), modifiers: .command)
    public static let copy = KeyChord(key: .character("c"), modifiers: .command)
}
