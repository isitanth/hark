import Foundation
import Testing

@testable import HarkCore

@Suite struct ScrollBarPreferenceTests {
    /// The values System Settings writes, a launch without the key, and one written by hand.
    @Test(arguments: [nil, "Automatic", "WhenScrolling", "sometimes"] as [String?])
    func scrollBarsHideAtRestUnlessAlways(_ current: String?) throws {
        let arguments = try #require(ScrollBarPreference.overlaid([:], current: current))
        #expect(arguments[ScrollBarPreference.key] as? String == "WhenScrolling")
    }

    @Test func alwaysStands() {
        #expect(ScrollBarPreference.overlaid([:], current: "Always") == nil)
    }

    /// The argument domain is replaced whole: a preview launch's flags and its language go with it or are lost.
    @Test func theOtherLaunchArgumentsAreKept() throws {
        let launch: [String: Any] = ["HarkDebugPreview": "settings", "AppleLanguages": ["fr"]]
        let arguments = try #require(ScrollBarPreference.overlaid(launch, current: "Automatic"))
        #expect(arguments["HarkDebugPreview"] as? String == "settings")
        #expect(arguments["AppleLanguages"] as? [String] == ["fr"])
        #expect(arguments.count == 3)
    }

    /// The key is AppKit's: `defaults read -g AppleShowScrollBars` shows the system's value under it.
    @Test func theKeyIsAppKits() {
        #expect(ScrollBarPreference.key == "AppleShowScrollBars")
    }
}
