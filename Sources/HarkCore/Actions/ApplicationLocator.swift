import Foundation

/// Finds the application a command names: a path as written, or a name looked for as `<name>.app` in the folders
/// macOS installs applications in, in order. Pure but for `exists`, which tests replace.
public struct ApplicationLocator: Sendable {
    public static let folders = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        "/System/Library/CoreServices", "~/Applications",
    ]

    private let home: String
    private let exists: @Sendable (String) -> Bool

    public init(
        home: String = NSHomeDirectory(),
        exists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.home = home
        self.exists = exists
    }

    /// Nil when nothing by that name, or at that path, exists. A name may carry `.app` or a subfolder
    /// ("Utilities/Terminal"); a path starts with `/` or `~`.
    public func url(for app: String) -> URL? {
        let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let path = expand(trimmed)
            return exists(path) ? URL(filePath: path, directoryHint: .isDirectory) : nil
        }
        let bundle = trimmed.lowercased().hasSuffix(".app") ? trimmed : trimmed + ".app"
        for folder in Self.folders {
            let path = expand(folder) + "/" + bundle
            if exists(path) { return URL(filePath: path, directoryHint: .isDirectory) }
        }
        return nil
    }

    /// What to write in `app:` for an application picked on disk: its name when the name finds this very app, its
    /// path otherwise. Symlinks are resolved on both sides, so /Applications/Safari.app and the cryptex copy it points
    /// to are one app.
    public func name(for picked: URL) -> String {
        let file = picked.lastPathComponent
        let name = file.lowercased().hasSuffix(".app") ? String(file.dropLast(4)) : file
        guard let found = url(for: name),
            Self.path(of: found.resolvingSymlinksInPath()) == Self.path(of: picked.resolvingSymlinksInPath())
        else { return Self.path(of: picked) }
        return name
    }

    /// The path without the trailing slash a directory URL's path carries.
    public static func path(of url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func expand(_ path: String) -> String {
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + path.dropFirst() : path
    }
}
