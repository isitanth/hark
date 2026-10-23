import Foundation
import Testing

@testable import HarkCore

/// A defaults suite of its own, kept in the temporary directory by its absolute name and removed at the end.
private final class ScratchDefaults {
    let directory: TemporaryDirectory
    let name: String
    let defaults: UserDefaults

    init() throws {
        directory = try TemporaryDirectory()
        name = directory.url.appendingPathComponent("preferences").path
        defaults = try #require(UserDefaults(suiteName: name))
    }

    /// A second handle on the same domain, as the next launch would open it.
    func reopened() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: name))
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

@Suite struct DockPreferenceTests {
    @Test func hiddenUnlessSet() throws {
        let scratch = try ScratchDefaults()
        #expect(DockPreference.showsInDock(in: scratch.defaults) == false)
    }

    /// The key is what `defaults read` shows; renaming it would silently take the icon away from whoever turned it on.
    @Test func theKeyIsHarkShowInDock() {
        #expect(DockPreference.key == "HarkShowInDock")
    }

    @Test(arguments: [true, false])
    func readsBackWhatWasSet(_ shown: Bool) throws {
        let scratch = try ScratchDefaults()
        DockPreference.set(shown, in: scratch.defaults)
        #expect(DockPreference.showsInDock(in: try scratch.reopened()) == shown)
    }

    /// Written by hand with `defaults write`: anything but a Bool, or the 0 and 1 UserDefaults hands back as one, is
    /// not an answer, and Hark stays a menu bar app.
    @Test(arguments: [
        MistypedDockValue(name: "a string", write: { $0.set("yes", forKey: DockPreference.key) }),
        MistypedDockValue(name: "a 2", write: { $0.set(2, forKey: DockPreference.key) }),
        MistypedDockValue(name: "a date", write: { $0.set(Date(), forKey: DockPreference.key) }),
    ])
    func aMistypedValueReadsAsHidden(_ value: MistypedDockValue) throws {
        let scratch = try ScratchDefaults()
        value.write(scratch.defaults)
        #expect(DockPreference.showsInDock(in: scratch.defaults) == false)
    }
}

struct MistypedDockValue: Sendable, CustomTestStringConvertible {
    let name: String
    let write: @Sendable (UserDefaults) -> Void

    var testDescription: String { name }
}
