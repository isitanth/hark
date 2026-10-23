import Foundation

/// Whether Hark shows in the Dock while it runs (Settings › General). Off unless set: Hark is a menu bar app, and
/// `LSUIElement` in Info.plist keeps a launch with it off from ever flashing an icon. On, Hark is a regular app: a Dock
/// icon, a place in ⌘Tab, its own menus, and its windows drawn as the active app's. It stays in the menu bar either
/// way. Stored in the app's UserDefaults domain beside `DictationPreferences`, and read at launch before any window.
public enum DockPreference {
    public static let key = "HarkShowInDock"

    /// A value that is not a Bool reads as off, the default.
    public static func showsInDock(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }

    public static func set(_ showsInDock: Bool, in defaults: UserDefaults) {
        defaults.set(showsInDock, forKey: key)
    }
}
