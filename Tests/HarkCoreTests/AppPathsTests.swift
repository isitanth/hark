import Foundation
import HarkCore
import Testing

@Suite struct AppPathsTests {
    /// Core ML writes its compiled encoders under the app's own caches folder, named for the bundle. Nothing in
    /// Hark creates this path, so nothing would notice if it drifted — and it was 1.9 GB when first found, at
    /// exactly this location, surviving a purge that only knew about the models folder.
    @Test func theCoreMLCacheIsWhereCoreMLActuallyPutsIt() {
        let paths = AppPaths.standard(bundleIdentifier: "com.anthonychambet.hark")
        let expected = URL.cachesDirectory
            .appending(path: "com.anthonychambet.hark/com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory)
        #expect(paths.coreMLCache.standardizedFileURL == expected.standardizedFileURL)
    }

    /// The layout built from the standard paths is the one the app's purge reads, so it must carry the cache.
    @Test func theModelLayoutCarriesTheCacheSoPurgeCanReachIt() {
        let paths = AppPaths.standard(bundleIdentifier: "com.anthonychambet.hark")
        #expect(ModelLayout(paths: paths).coreMLCache == paths.coreMLCache)
    }

    @Test func modelsLiveUnderApplicationSupport() {
        let paths = AppPaths.standard(bundleIdentifier: "com.anthonychambet.hark")
        #expect(paths.models.path(percentEncoded: false).hasSuffix("Application Support/Hark/models/"))
    }

    /// Next to commands.yaml, so it stays on the same volume, and hidden, so nobody edits the wrong file.
    @Test func theLastGoodConfigIsAHiddenFileNextToCommandsYAML() {
        let paths = AppPaths.standard(bundleIdentifier: "com.anthonychambet.hark")
        #expect(paths.lastGoodCommands.lastPathComponent == ".commands.lastgood.yaml")
        #expect(paths.lastGoodCommands.deletingLastPathComponent() == paths.commands.deletingLastPathComponent())
        #expect(!paths.lastGoodCommands.hasDirectoryPath)
    }
}
