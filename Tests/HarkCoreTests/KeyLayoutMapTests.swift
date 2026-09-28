import Foundation
import HarkCore
import Testing

private let qwerty = KeyLayoutMap(
    plain: [0: "a", 9: "v", 12: "q", 18: "1", 83: "1"],
    command: [0: "a", 9: "v", 12: "q"])
private let azerty = KeyLayoutMap(
    plain: [0: "q", 9: "v", 12: "a", 18: "&", 83: "1"],
    command: [0: "q", 9: "v", 12: "a"])
private let commandSwitches = KeyLayoutMap(plain: [47: "v", 9: "k"], command: [9: "v", 47: "."])

struct LookupCase: Sendable, CustomTestStringConvertible {
    let name: String
    let map: KeyLayoutMap
    let character: Character
    let modifiers: KeyModifiers
    let code: UInt16?

    var testDescription: String { name }
}

let lookupCases: [LookupCase] = [
    .init(name: "qwerty v", map: qwerty, character: "v", modifiers: [], code: 9),
    .init(name: "qwerty V finds v", map: qwerty, character: "V", modifiers: .command, code: 9),
    .init(name: "qwerty 1: main row beats keypad", map: qwerty, character: "1", modifiers: [], code: 18),
    .init(name: "qwerty 1 absent from command table", map: qwerty, character: "1", modifiers: .command, code: nil),
    .init(name: "azerty a", map: azerty, character: "a", modifiers: [], code: 12),
    .init(name: "azerty q under command", map: azerty, character: "q", modifiers: .command, code: 0),
    .init(name: "azerty 1 is keypad only", map: azerty, character: "1", modifiers: [], code: 83),
    .init(name: "azerty &", map: azerty, character: "&", modifiers: [], code: 18),
    .init(name: "missing character", map: azerty, character: "z", modifiers: [], code: nil),
    .init(name: "command table selected", map: commandSwitches, character: "v", modifiers: .command, code: 9),
    .init(name: "plain table without command", map: commandSwitches, character: "v", modifiers: [], code: 47),
    .init(
        name: "shift and option ignored", map: commandSwitches, character: "v", modifiers: [.shift, .option],
        code: 47),
    .init(
        name: "command with shift still command", map: commandSwitches, character: "v",
        modifiers: [.command, .shift], code: 9),
]

struct LayoutCase: Sendable, CustomTestStringConvertible {
    let id: String
    let character: Character
    let modifiers: KeyModifiers
    let code: UInt16?

    var testDescription: String { "\(id) \(modifiers.contains(.command) ? "⌘" : "")\(character)" }
}

let layoutCases: [LayoutCase] = [
    .init(id: "com.apple.keylayout.US", character: "v", modifiers: [], code: 9),
    .init(id: "com.apple.keylayout.US", character: "a", modifiers: [], code: 0),
    .init(id: "com.apple.keylayout.US", character: "q", modifiers: [], code: 12),
    .init(id: "com.apple.keylayout.US", character: "z", modifiers: [], code: 6),
    .init(id: "com.apple.keylayout.US", character: "w", modifiers: [], code: 13),
    .init(id: "com.apple.keylayout.US", character: "m", modifiers: [], code: 46),
    .init(id: "com.apple.keylayout.US", character: "1", modifiers: [], code: 18),
    .init(id: "com.apple.keylayout.US", character: "v", modifiers: .command, code: 9),
    .init(id: "com.apple.keylayout.US", character: "q", modifiers: .command, code: 12),
    .init(id: "com.apple.keylayout.French", character: "v", modifiers: [], code: 9),
    .init(id: "com.apple.keylayout.French", character: "a", modifiers: [], code: 12),
    .init(id: "com.apple.keylayout.French", character: "q", modifiers: [], code: 0),
    .init(id: "com.apple.keylayout.French", character: "z", modifiers: [], code: 13),
    .init(id: "com.apple.keylayout.French", character: "w", modifiers: [], code: 6),
    .init(id: "com.apple.keylayout.French", character: "m", modifiers: [], code: 41),
    .init(id: "com.apple.keylayout.French", character: "&", modifiers: [], code: 18),
    .init(id: "com.apple.keylayout.French", character: "1", modifiers: [], code: 83),
    .init(id: "com.apple.keylayout.French", character: "v", modifiers: .command, code: 9),
    .init(id: "com.apple.keylayout.French", character: "q", modifiers: .command, code: 0),
    .init(id: "com.apple.keylayout.Dvorak", character: "v", modifiers: [], code: 47),
    .init(id: "com.apple.keylayout.Dvorak", character: "v", modifiers: .command, code: 47),
    .init(id: "com.apple.keylayout.Dvorak", character: "q", modifiers: .command, code: 7),
    .init(id: "com.apple.keylayout.DVORAK-QWERTYCMD", character: "v", modifiers: [], code: 47),
    .init(id: "com.apple.keylayout.DVORAK-QWERTYCMD", character: "v", modifiers: .command, code: 9),
    .init(id: "com.apple.keylayout.DVORAK-QWERTYCMD", character: "q", modifiers: .command, code: 12),
    .init(id: "com.apple.keylayout.German", character: "z", modifiers: [], code: 16),
    // Dead keys, measured: present only when UCKeyTranslate gets the no-dead-keys mask.
    .init(id: "com.apple.keylayout.French", character: "^", modifiers: [], code: 33),
    .init(id: "com.apple.keylayout.French", character: "`", modifiers: [], code: 42),
    .init(id: "com.apple.keylayout.German", character: "´", modifiers: [], code: 24),
    .init(id: "com.apple.keylayout.US", character: "`", modifiers: [], code: 50),
]

@Suite struct KeyLayoutMapTests {
    @Test(arguments: lookupCases)
    func lookup(_ c: LookupCase) {
        #expect(c.map.keyCode(for: c.character, modifiers: c.modifiers) == c.code)
    }

    @Test(
        arguments: [
            ("a", UInt16?(0)), ("V", 9), ("q", 12), ("z", 6), ("m", 46), ("0", 29), ("1", 18), ("9", 25),
            ("é", nil), ("&", nil), (" ", nil),
        ] as [(Character, UInt16?)])
    func ansi(_ character: Character, _ code: UInt16?) {
        #expect(KeyLayoutMap.ansiKeyCode(for: character) == code)
    }

    @MainActor @Test(arguments: layoutCases)
    func realLayout(_ c: LayoutCase) throws {
        let map = try #require(KeyLayoutMap.installed(c.id))
        #expect(map.keyCode(for: c.character, modifiers: c.modifiers) == c.code)
    }

    @MainActor @Test func currentLayoutTypesCommandV() throws {
        let map = try #require(KeyLayoutMap.current())
        #expect(map.keyCode(for: "v", modifiers: .command) != nil)
    }

    @MainActor @Test func pasteChordOnFrench() throws {
        let map = try #require(KeyLayoutMap.installed("com.apple.keylayout.French"))
        guard case .character(let character) = KeyChord.paste.key else {
            Issue.record("paste is not a character chord")
            return
        }
        #expect(map.keyCode(for: character, modifiers: KeyChord.paste.modifiers) == 9)
    }

    @MainActor @Test func unknownLayoutIsNil() {
        #expect(KeyLayoutMap.installed("com.example.no-such-layout") == nil)
    }
}
