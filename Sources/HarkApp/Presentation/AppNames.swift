import AppKit

/// The name an app shows in Finder, for the bundle IDs the log records. The log keeps the bundle ID, which is what
/// identifies an app; people recognise the name.
enum AppNames {
    private static var cache: [String: String] = [:]

    /// The installed app's localized name, or `target` as logged when nothing is installed under that bundle ID (or
    /// it is not one: `pid:1234`, `unknown`).
    static func name(for target: String) -> String {
        if let known = cache[target] { return known }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
            .flatMap { try? $0.resourceValues(forKeys: [.localizedNameKey]).localizedName }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        cache[target] = name ?? target
        return name ?? target
    }
}
