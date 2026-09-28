import Foundation

/// On-disk layout under ~/Library/Application Support/Hark. The app is not sandboxed.
public struct AppPaths: Sendable, Equatable {
    public let root: URL
    /// This app's own folder under `~/Library/Caches`, where the system keeps derived data on our behalf.
    public let caches: URL

    public init(root: URL, caches: URL? = nil) {
        self.root = root
        self.caches = caches ?? root.appending(path: "Caches", directoryHint: .isDirectory)
    }

    public static func standard(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> AppPaths {
        AppPaths(
            root: URL.applicationSupportDirectory.appending(path: "Hark", directoryHint: .isDirectory),
            caches: URL.cachesDirectory.appending(
                path: bundleIdentifier ?? "com.anthonychambet.hark", directoryHint: .isDirectory))
    }

    /// Core ML's Neural Engine build of every encoder this app has loaded.
    ///
    /// Core ML writes it, not Hark, under our caches folder the first time an encoder is loaded — that is the
    /// "first run on a device may take a while" whisper logs — and rebuilds it on the next load if it is gone.
    /// It is easy to miss because nothing in the code creates it, and it is large: 1.9 GB after small, medium
    /// and large-v3 had each been loaded once. Safe to remove whenever no model is loaded.
    public var coreMLCache: URL {
        caches.appending(path: "com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory)
    }

    public var logs: URL { root.appending(path: "logs", directoryHint: .isDirectory) }
    public var commands: URL { root.appending(path: "commands.yaml", directoryHint: .notDirectory) }
    /// The last commands.yaml that parsed, for a cold start with a bad file. Hidden, because it is not for editing.
    public var lastGoodCommands: URL {
        root.appending(path: ".commands.lastgood.yaml", directoryHint: .notDirectory)
    }
    public var models: URL { root.appending(path: "models", directoryHint: .isDirectory) }
}
