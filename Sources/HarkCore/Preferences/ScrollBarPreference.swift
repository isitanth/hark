import Foundation

/// Scroll bars in Hark's windows hide at rest and show while scrolling, as macOS draws them with a trackpad alone.
///
/// Under System Settings' "Show scroll bars: Automatically based on mouse or trackpad", macOS gives every app scroll
/// bars that never hide as soon as a mouse is connected: a bundled app starts with overlay scrollers, then AppKit's
/// preference change, posted just after launch, turns them all legacy (measured 2026-10-23 with a Bluetooth mouse
/// beside the trackpad). SwiftUI sets each scroll view's style from that same preference on every update of the
/// view, a selection or a reloaded list, so an override per scroll view does not hold. The preference is the one input
/// AppKit and SwiftUI both read, so Hark sets it for its own process, in the argument domain: in memory, never
/// written to disk. "Always", the user's explicit choice, stands. The value in force is read once, at launch.
public enum ScrollBarPreference {
    public static let key = "AppleShowScrollBars"

    /// The launch arguments with overlay scroll bars added, or nil when "Always" is in force, from System Settings or
    /// given at launch.
    public static func overlaid(_ arguments: [String: Any], current: String?) -> [String: Any]? {
        guard current != "Always" else { return nil }
        var arguments = arguments
        arguments[key] = "WhenScrolling"
        return arguments
    }

    /// Before `NSApplication` starts, so the first scroll view already takes it. The argument domain is the whole
    /// process's and holds the other launch arguments, `-HarkDebugPreview` and `-AppleLanguages` among them: they are
    /// kept.
    public static func apply(to defaults: UserDefaults) {
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let overlaid = overlaid(arguments, current: defaults.string(forKey: key)) else { return }
        defaults.setVolatileDomain(overlaid, forName: UserDefaults.argumentDomain)
    }
}
