import HarkCore
import Testing

/// ⌘ and a digit pick a block of the live turn by the key's place, not its character (M14.7, measured on an AZERTY
/// Mac: ⌘ with the key that carries 1 carries « & »).
@Suite struct ResultPickKeyTests {
    /// The digit row, 1 to 9, by key code: `kVK_ANSI_1` to `kVK_ANSI_9`, whose codes are not in key order.
    @Test(arguments: [
        (UInt16(18), 0), (19, 1), (20, 2), (21, 3), (23, 4), (22, 5), (26, 6), (28, 7), (25, 8),
    ])
    func theDigitRowPicksByPlace(keyCode: UInt16, position: Int) {
        #expect(ResultPickKey.position(keyCode: keyCode, modifiers: .command) == position)
    }

    /// AZERTY's « & », « é » and « " » keys are the 1, 2 and 3 keys: ⌘ with them picks the turn's first three blocks.
    @Test func azertysFirstThreeKeysPickTheFirstThreeBlocks() {
        #expect(ResultPickKey.position(keyCode: 18, modifiers: .command) == 0)
        #expect(ResultPickKey.position(keyCode: 19, modifiers: .command) == 1)
        #expect(ResultPickKey.position(keyCode: 20, modifiers: .command) == 2)
    }

    /// Only ⌘ alone picks: no modifier is typing, and ⌘ with ⇧, ⌥ or ⌃ is another shortcut (here ⌘⇧2 is a screenshot
    /// tool's).
    @Test(arguments: [
        KeyModifiers(), .shift, .option, .control, [.command, .shift], [.command, .option], [.command, .control],
        [.command, .shift, .option, .control],
    ])
    func onlyCommandAlonePicks(modifiers: KeyModifiers) {
        #expect(ResultPickKey.position(keyCode: 18, modifiers: modifiers) == nil)
        #expect(ResultPickKey.position(keyCode: 20, modifiers: modifiers) == nil)
    }

    /// Esc, Return, a letter (12: Q on QWERTY, A on AZERTY), 0 and the keypad's 1 pick nothing.
    @Test(arguments: [UInt16(53), 36, 12, 29, 83])
    func otherKeysPickNothing(keyCode: UInt16) {
        #expect(ResultPickKey.position(keyCode: keyCode, modifiers: .command) == nil)
    }
}
