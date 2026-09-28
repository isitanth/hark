import Foundation
import HarkCore
import Testing

private let slack = AppIdentity(
    bundleID: "com.tinyspeck.slackmacgap", name: "Slack", processID: 801, embedsChromium: true)
private let settableText = FocusedElement(role: "AXTextArea", acceptsSelectedText: true, valueSettable: true)

@Suite struct AppOverrideTests {
    @Test func entryBeatsGlobal() {
        let apps = ["com.apple.mail": AppOverride(insert: .paste)]
        let resolved = FocusResolver.mode(for: Fixture.mail, global: .accessibility, apps: apps)
        #expect(resolved.mode == .paste)
        #expect(resolved.overridden)
    }

    @Test func otherAppsKeepGlobal() {
        let apps = ["com.apple.notes": AppOverride(insert: .clipboard)]
        let resolved = FocusResolver.mode(for: Fixture.mail, global: .paste, apps: apps)
        #expect(resolved.mode == .paste)
        #expect(!resolved.overridden)
    }

    @Test func bundleIDMatchesCaseInsensitively() {
        let apps = ["com.TinySpeck.SlackMacGap": AppOverride(insert: .clipboard)]
        let resolved = FocusResolver.mode(for: slack, global: .accessibility, apps: apps)
        #expect(resolved.mode == .clipboard)
        #expect(resolved.overridden)
    }

    @Test func noBundleIDUsesGlobal() {
        let app = AppIdentity(bundleID: nil, name: "Unbundled", processID: 802)
        let apps = ["": AppOverride(insert: .clipboard)]
        let resolved = FocusResolver.mode(for: app, global: .paste, apps: apps)
        #expect(resolved.mode == .paste)
        #expect(!resolved.overridden)
        #expect(FocusResolver.mode(for: nil, global: .paste, apps: apps).overridden == false)
    }

    @Test func accessibilityOverrideOnChromiumInserts() {
        let apps = ["com.tinyspeck.slackmacgap": AppOverride(insert: .accessibility)]
        let focus = FocusSnapshot(app: slack, element: settableText)
        #expect(FocusResolver.decide(focus: focus, global: .accessibility, apps: apps) == .insert(.axInsert))
    }

    @Test func clipboardOverrideCopies() {
        let apps = ["com.apple.mail": AppOverride(insert: .clipboard)]
        let focus = FocusSnapshot(app: Fixture.mail, element: settableText)
        #expect(FocusResolver.decide(focus: focus, global: .accessibility, apps: apps) == .copy(.chosen))
    }

    @Test func pasteOverrideWithUnknownElementPastes() {
        let apps = ["com.apple.mail": AppOverride(insert: .paste)]
        let focus = FocusSnapshot(app: Fixture.mail)
        #expect(FocusResolver.decide(focus: focus, global: .accessibility, apps: apps) == .insert(.paste))
    }

    @Test func tableParsedFromYAML() throws {
        let yaml = """
            version: 2
            apps:
              com.TinySpeck.SlackMacGap:
                insert: accessibility
              com.apple.mail:
                insert: clipboard
              com.apple.notes:
                insert: paste
            """
        let config = try CommandConfig.parse(Data(yaml.utf8))
        let notes = AppIdentity(bundleID: "com.apple.Notes", name: "Notes", processID: 803)

        let decide = { (app: AppIdentity, element: FocusedElement?) in
            FocusResolver.decide(
                focus: FocusSnapshot(app: app, element: element), global: .accessibility, apps: config.apps)
        }
        #expect(decide(slack, settableText) == .insert(.axInsert))
        #expect(decide(Fixture.mail, settableText) == .copy(.chosen))
        #expect(decide(notes, nil) == .insert(.paste))
    }
}
