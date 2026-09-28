import Foundation
import HarkCore
import Testing

private let textArea = FocusedElement(role: "AXTextArea", acceptsSelectedText: true, valueSettable: true)
private let terminalText = FocusedElement(role: "AXTextArea")
private let button = FocusedElement(role: "AXButton")
private let noRole = FocusedElement(role: nil)

private let iterm = AppIdentity(bundleID: "com.googlecode.iTerm2", name: "iTerm2", processID: 601)
private let claude = AppIdentity(
    bundleID: "com.anthropic.claudefordesktop", name: "Claude", processID: 602, embedsChromium: true)
private let electron = AppIdentity(bundleID: "com.example.electron", name: "Tool", processID: 603, embedsChromium: true)

struct KindCase: Sendable, CustomTestStringConvertible {
    let name: String
    let element: FocusedElement?
    let kind: FocusKind

    var testDescription: String { name }
}

let kindCases: [KindCase] = [
    .init(name: "no element", element: nil, kind: .unknown),
    .init(name: "no role", element: noRole, kind: .unknown),
    .init(name: "no role, settable selection", element: .init(role: nil, acceptsSelectedText: true), kind: .unknown),
    .init(name: "text field", element: .init(role: "AXTextField"), kind: .text),
    .init(name: "text area", element: .init(role: "AXTextArea"), kind: .text),
    .init(name: "combo box", element: .init(role: "AXComboBox"), kind: .text),
    .init(name: "search field", element: .init(role: "AXSearchField"), kind: .text),
    .init(
        name: "secure text field subrole", element: .init(role: "AXTextField", subrole: "AXSecureTextField"),
        kind: .text),
    .init(
        name: "web area with settable selection", element: .init(role: "AXWebArea", acceptsSelectedText: true),
        kind: .text),
    .init(
        name: "group with settable value only", element: .init(role: "AXGroup", valueSettable: true),
        kind: .notText),
    .init(
        name: "web area with settable value: a Mail draft", element: .init(role: "AXWebArea", valueSettable: true),
        kind: .text),
    .init(name: "web area, value not settable: a received message", element: .init(role: "AXWebArea"), kind: .notText),
    .init(name: "slider with settable value", element: .init(role: "AXSlider", valueSettable: true), kind: .notText),
    .init(name: "button", element: button, kind: .notText),
    .init(name: "static text", element: .init(role: "AXStaticText"), kind: .notText),
]

struct DecideCase: Sendable, CustomTestStringConvertible {
    let name: String
    let focus: FocusSnapshot?
    let global: InsertionMode
    var apps: [String: AppOverride] = [:]
    let decision: Decision

    var testDescription: String { name }
}

let decideCases: [DecideCase] = [
    // 1, 2: no focus, secure input
    .init(name: "1 no focus", focus: nil, global: .accessibility, decision: .copy(.noTextField)),
    .init(
        name: "2 secure input in a text field",
        focus: .init(app: Fixture.mail, element: textArea, isSecureInput: true), global: .accessibility,
        decision: .copy(.secureField)),
    .init(
        name: "2 secure input beats an apps: paste",
        focus: .init(app: claude, element: textArea, isSecureInput: true), global: .accessibility,
        apps: ["com.anthropic.claudefordesktop": .init(insert: .paste)], decision: .copy(.secureField)),
    // Mail's draft body: a web area whose value is settable takes a paste; a received message does not (M9.0).
    .init(
        name: "Mail draft body: paste",
        focus: .init(app: Fixture.mail, element: .init(role: "AXWebArea", valueSettable: true)),
        global: .accessibility, decision: .insert(.paste, fallback: true)),
    .init(
        name: "Mail received message: the clipboard",
        focus: .init(app: Fixture.mail, element: .init(role: "AXWebArea")), global: .accessibility,
        decision: .copy(.noTextField)),
    // 3: clipboard
    .init(
        name: "3 global clipboard", focus: .init(app: Fixture.mail, element: textArea), global: .clipboard,
        decision: .copy(.chosen)),
    .init(
        name: "3 global clipboard beats needsPaste", focus: .init(app: claude, element: textArea),
        global: .clipboard, decision: .copy(.chosen)),
    .init(
        name: "3 apps: clipboard", focus: .init(app: Fixture.mail, element: textArea), global: .accessibility,
        apps: ["com.apple.mail": .init(insert: .clipboard)], decision: .copy(.chosen)),
    // 5: paste path
    .init(
        name: "5 Electron, unknown element", focus: .init(app: claude), global: .accessibility,
        decision: .insert(.paste)),
    .init(
        name: "5 Electron, settable text", focus: .init(app: electron, element: textArea), global: .accessibility,
        decision: .insert(.paste)),
    .init(
        name: "5 Electron, button", focus: .init(app: electron, element: button), global: .accessibility,
        decision: .copy(.noTextField)),
    .init(
        name: "5 terminal under global paste, unknown", focus: .init(app: iterm), global: .paste,
        decision: .insert(.paste)),
    .init(
        name: "5 apps: paste on a native app, unknown", focus: .init(app: Fixture.mail), global: .accessibility,
        apps: ["com.apple.mail": .init(insert: .paste)], decision: .insert(.paste)),
    .init(
        name: "5 apps: paste on a native app, button", focus: .init(app: Fixture.mail, element: button),
        global: .accessibility, apps: ["com.apple.mail": .init(insert: .paste)], decision: .copy(.noTextField)),
    // 6: global paste, native app
    .init(
        name: "6 global paste, text", focus: .init(app: Fixture.mail, element: textArea), global: .paste,
        decision: .insert(.paste)),
    .init(
        name: "6 global paste, unknown", focus: .init(app: Fixture.mail), global: .paste, decision: .copy(.noTextField)),
    .init(
        name: "6 global paste, button", focus: .init(app: Fixture.mail, element: button), global: .paste,
        decision: .copy(.noTextField)),
    // 7: accessibility
    .init(
        name: "7 settable text", focus: .init(app: Fixture.mail, element: textArea), global: .accessibility,
        decision: .insert(.axInsert)),
    .init(
        name: "7 text without settable selection", focus: .init(app: Fixture.mail, element: terminalText),
        global: .accessibility, decision: .insert(.paste)),
    .init(
        name: "7 unknown", focus: .init(app: Fixture.mail, element: noRole), global: .accessibility,
        decision: .copy(.noTextField)),
    .init(
        name: "7 button", focus: .init(app: Fixture.mail, element: button), global: .accessibility,
        decision: .copy(.noTextField)),
    .init(
        name: "7 no app", focus: .init(app: nil, element: textArea), global: .accessibility,
        decision: .insert(.axInsert)),
    .init(
        name: "7 apps: accessibility on Electron beats the list", focus: .init(app: claude, element: textArea),
        global: .paste, apps: ["com.anthropic.claudefordesktop": .init(insert: .accessibility)],
        decision: .insert(.axInsert)),
    .init(
        name: "7 apps: accessibility on Electron, unknown", focus: .init(app: claude), global: .accessibility,
        apps: ["com.anthropic.claudefordesktop": .init(insert: .accessibility)], decision: .copy(.noTextField)),
]

struct NeedsPasteCase: Sendable, CustomTestStringConvertible {
    let name: String
    let app: AppIdentity?
    let needsPaste: Bool

    var testDescription: String { name }
}

private func app(_ bundleID: String?, chromium: Bool = false) -> AppIdentity {
    AppIdentity(bundleID: bundleID, name: nil, processID: 700, embedsChromium: chromium)
}

let needsPasteCases: [NeedsPasteCase] = [
    .init(name: "embeds Chromium, unlisted", app: app("com.example.electron", chromium: true), needsPaste: true),
    .init(name: "embeds Chromium, no bundle ID", app: app(nil, chromium: true), needsPaste: true),
    .init(name: "iTerm2 in mixed case", app: app("com.googlecode.iTerm2"), needsPaste: true),
    .init(name: "Terminal in mixed case", app: app("com.apple.Terminal"), needsPaste: true),
    .init(name: "Chrome", app: app("com.google.Chrome"), needsPaste: true),
    .init(name: "Firefox", app: app("org.mozilla.firefox"), needsPaste: true),
    .init(name: "Slack by bundle ID alone", app: app("com.tinyspeck.slackmacgap"), needsPaste: true),
    .init(name: "JetBrains prefix", app: app("com.jetbrains.intellij"), needsPaste: true),
    .init(name: "JetBrains prefix in mixed case", app: app("com.JetBrains.PyCharm"), needsPaste: true),
    .init(name: "Mail", app: Fixture.mail, needsPaste: false),
    .init(name: "a lookalike of a listed ID", app: app("com.google.chromecast"), needsPaste: false),
    .init(name: "no bundle ID", app: app(nil), needsPaste: false),
    .init(name: "no app", app: nil, needsPaste: false),
]

/// With the fallback off, only a copy the user chose survives; everything that would have been caught by the
/// clipboard is discarded instead.
let fallbackOffCases: [DecideCase] = [
    .init(name: "no focus", focus: nil, global: .accessibility, decision: .discard(.clipboardFallbackDisabled)),
    .init(
        name: "secure input", focus: .init(app: Fixture.mail, element: textArea, isSecureInput: true),
        global: .accessibility, decision: .discard(.clipboardFallbackDisabled)),
    .init(
        name: "no text field", focus: .init(app: Fixture.mail, element: button), global: .accessibility,
        decision: .discard(.clipboardFallbackDisabled)),
    .init(
        name: "nothing focused in a native app", focus: .init(app: Fixture.mail), global: .accessibility,
        decision: .discard(.clipboardFallbackDisabled)),
    .init(
        name: "a button in a Chromium app", focus: .init(app: claude, element: button), global: .accessibility,
        decision: .discard(.clipboardFallbackDisabled)),
    // The clipboard as the destination, not as a net: still a copy.
    .init(
        name: "clipboard-only mode", focus: .init(app: Fixture.mail, element: textArea), global: .clipboard,
        decision: .copy(.chosen)),
    .init(
        name: "clipboard-only mode with nothing focused", focus: .init(app: Fixture.mail), global: .clipboard,
        decision: .copy(.chosen)),
    .init(
        name: "an apps: entry that says clipboard", focus: .init(app: Fixture.mail, element: textArea),
        global: .accessibility, apps: ["com.apple.mail": .init(insert: .clipboard)], decision: .copy(.chosen)),
    .init(
        name: "a password field in clipboard-only mode",
        focus: .init(app: Fixture.mail, element: textArea, isSecureInput: true), global: .clipboard,
        decision: .copy(.chosen)),
    // An insertion still happens; the flag rides along for the failure.
    .init(
        name: "a text field still takes the text", focus: .init(app: Fixture.mail, element: textArea),
        global: .accessibility, decision: .insert(.axInsert, fallback: false)),
    .init(
        name: "a Chromium app still gets a paste", focus: .init(app: claude), global: .accessibility,
        decision: .insert(.paste, fallback: false)),
]

@Suite struct FocusResolverTests {
    @Test(arguments: kindCases)
    func kind(_ c: KindCase) {
        #expect(FocusResolver.kind(of: c.element) == c.kind)
    }

    @Test(arguments: decideCases)
    func decide(_ c: DecideCase) {
        #expect(FocusResolver.decide(focus: c.focus, global: c.global, apps: c.apps) == c.decision)
    }

    @Test(arguments: needsPasteCases)
    func needsPaste(_ c: NeedsPasteCase) {
        #expect(FocusResolver.needsPaste(c.app) == c.needsPaste)
    }

    @Test(arguments: fallbackOffCases)
    func decideWithTheFallbackOff(_ c: DecideCase) {
        #expect(
            FocusResolver.decide(focus: c.focus, global: c.global, apps: c.apps, clipboardFallback: false)
                == c.decision)
    }

    /// Every combination again with the fallback off: what was a copy is now a discard, unless the clipboard is
    /// where the user asked the text to go, and an insertion is unchanged but for the flag it carries.
    @Test func theFallbackOffOnlyTurnsCopiesIntoDiscards() {
        let elements: [FocusKind: FocusedElement?] = [.text: textArea, .notText: button, .unknown: nil]
        for mode in InsertionMode.allCases {
            for kind in FocusKind.allCases {
                for pastes in [false, true] {
                    for secure in [false, true] {
                        let target = pastes ? claude : Fixture.mail
                        let label = "\(mode) \(kind) needsPaste=\(pastes) secure=\(secure)"
                        let focus = FocusSnapshot(
                            app: target, element: elements[kind] ?? nil, isSecureInput: secure)
                        let on = FocusResolver.decide(focus: focus, global: mode, apps: [:])
                        let off = FocusResolver.decide(
                            focus: focus, global: mode, apps: [:], clipboardFallback: false)
                        switch on {
                        case .copy(let reason):
                            let expected: Decision =
                                mode == .clipboard ? .copy(.chosen) : .discard(.clipboardFallbackDisabled)
                            #expect(off == expected, "\(label)")
                            let why: ClipboardReason =
                                mode == .clipboard ? .chosen : secure ? .secureField : .noTextField
                            #expect(reason == why, "\(label)")
                        case .insert(let plan, _):
                            #expect(off == .insert(plan, fallback: false), "\(label)")
                        case .command, .discard:
                            Issue.record("\(label) -> \(on)")
                        }
                    }
                }
            }
        }
    }

    /// The panel's Paste: the user has asked for the text to go into the field, so clipboard-only mode is not one
    /// of the answers, but a password field and a focus that takes no text still are.
    @Test func pastePlanIgnoresClipboardOnlyModeAndNothingElse() {
        let text = FocusSnapshot(app: Fixture.mail, element: textArea)
        #expect(FocusResolver.pastePlan(focus: text) == .axInsert)
        #expect(
            FocusResolver.pastePlan(focus: text, apps: ["com.apple.mail": .init(insert: .clipboard)]) == .axInsert)
        #expect(FocusResolver.pastePlan(focus: text, apps: ["com.apple.mail": .init(insert: .paste)]) == .paste)
        #expect(FocusResolver.pastePlan(focus: .init(app: claude)) == .paste, "a Chromium app still gets a paste")
        #expect(FocusResolver.pastePlan(focus: .init(app: iterm, element: terminalText)) == .paste)

        #expect(FocusResolver.pastePlan(focus: nil) == nil)
        #expect(FocusResolver.pastePlan(focus: .init(app: Fixture.mail)) == nil, "nothing focused")
        #expect(FocusResolver.pastePlan(focus: .init(app: Fixture.mail, element: button)) == nil)
        #expect(
            FocusResolver.pastePlan(focus: .init(app: Fixture.mail, element: textArea, isSecureInput: true)) == nil,
            "a password field takes nothing, however it was asked")
    }

    /// Wherever dictation would have been inserted, an explicit Paste goes the same way.
    @Test func pastePlanAgreesWithTheDecisionWhereverTextIsInserted() {
        let elements: [FocusKind: FocusedElement?] = [.text: textArea, .notText: button, .unknown: nil]
        for kind in FocusKind.allCases {
            for pastes in [false, true] {
                let target = pastes ? claude : Fixture.mail
                let focus = FocusSnapshot(app: target, element: elements[kind] ?? nil)
                let label = "\(kind) needsPaste=\(pastes)"
                if case .insert(let plan, _) = FocusResolver.decide(
                    focus: focus, global: .accessibility, apps: [:])
                {
                    #expect(FocusResolver.pastePlan(focus: focus) == plan, "\(label)")
                }
            }
        }
    }

    @Test func listedIDsAreLowercase() {
        #expect(FocusResolver.alwaysPaste.allSatisfy { $0 == $0.lowercased() })
        #expect(FocusResolver.alwaysPastePrefixes.allSatisfy { $0 == $0.lowercased() })
    }

    /// Every combination of mode, element kind, app class and override: never a command or a discard, clipboard
    /// always copies, secure input always copies.
    @Test func everyCombinationStaysInItsLane() {
        let elements: [FocusKind: FocusedElement?] = [.text: textArea, .notText: button, .unknown: nil]
        for mode in InsertionMode.allCases {
            for kind in FocusKind.allCases {
                for pastes in [false, true] {
                    for overridden in [false, true] {
                        let target = pastes ? claude : Fixture.mail
                        let apps: [String: AppOverride] =
                            overridden ? [target.bundleID ?? "": .init(insert: mode)] : [:]
                        let global: InsertionMode = overridden ? .accessibility : mode
                        let element = elements[kind] ?? nil
                        let label = "\(mode) \(kind) needsPaste=\(pastes) overridden=\(overridden)"

                        let open = FocusSnapshot(app: target, element: element)
                        let decision = FocusResolver.decide(focus: open, global: global, apps: apps)
                        switch decision {
                        case .command, .discard: Issue.record("\(label) -> \(decision)")
                        case .insert, .copy: break
                        }
                        if mode == .clipboard { #expect(decision == .copy(.chosen), "\(label)") }

                        let secure = FocusSnapshot(app: target, element: element, isSecureInput: true)
                        let hidden: Decision = mode == .clipboard ? .copy(.chosen) : .copy(.secureField)
                        #expect(FocusResolver.decide(focus: secure, global: global, apps: apps) == hidden, "\(label)")
                    }
                }
            }
        }
    }
}
