/// ⌘ and a digit pick a block of the live turn's answer (M14, plan §4.4) by the key's place on the keyboard, not by its
/// character. Measured in M14.7 on an AZERTY Mac: the key that carries 1 types « & », so ⌘ with it carries « & » and a
/// shortcut bound to the character 1 fires only with ⌘⇧. The key codes are the digit row's (`kVK_ANSI_1` to
/// `kVK_ANSI_9`), the same physical keys on every layout.
public enum ResultPickKey {
    /// The digit row's key codes, by the block's position in the live turn (0 is its first block: ① in a first turn,
    /// the turn's own first number after a follow-up).
    static let digitRow: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]

    /// The position a key press picks, or nil. Only ⌘ alone picks: with ⇧, ⌥ or ⌃ held too the press is left to the
    /// app, as are the keypad's digits. `modifiers` carries those four keys only, so Caps Lock and fn never matter.
    public static func position(keyCode: UInt16, modifiers: KeyModifiers) -> Int? {
        guard modifiers == .command else { return nil }
        return digitRow[keyCode]
    }
}
