import Foundation
import HarkCore
import Testing

/// The store on the real `DispatchFileWatcher`, the continuous clock and the real 100 ms debounce, driven by the three
/// ways a file changes on disk: written in place, replaced by a rename, deleted and created again.
@Suite("Config file watcher", .serialized, .timeLimit(.minutes(1)))
struct ConfigWatcherTests {
    private struct Live {
        let directory: TemporaryDirectory
        let file: URL
        let store: ConfigStore

        init() async throws {
            directory = try TemporaryDirectory()
            file = directory.url.appending(path: "commands.yaml")
            try Data(ConfigTexts.valid("one").utf8).write(to: file)
            store = ConfigStore(
                fileURL: file, lastGoodURL: directory.url.appending(path: ".commands.lastgood.yaml"), defaultURL: nil)
            await store.start()
        }

        /// Polls rather than iterating `snapshots`: a cancelled iteration would end the stream for good.
        func waitFor(_ phrase: String) async throws -> Bool {
            let expected = try ConfigTexts.config(phrase)
            for _ in 0..<250 {
                if await store.current.config == expected { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }

        func writeInPlace(_ phrase: String) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(ConfigTexts.valid(phrase).utf8))
        }
    }

    @Test("a file written in place reloads")
    func inPlaceWrite() async throws {
        let live = try await Live()
        try live.writeInPlace("two")
        #expect(try await live.waitFor("two"))
        await live.store.stop()
    }

    @Test("a file replaced by a rename reloads, and so does an in-place write to the file that replaced it")
    func renameOverThenInPlace() async throws {
        let live = try await Live()
        try Data(ConfigTexts.valid("two").utf8).write(to: live.file, options: .atomic)
        #expect(try await live.waitFor("two"))
        try live.writeInPlace("three")
        #expect(try await live.waitFor("three"))
        await live.store.stop()
    }

    @Test("a file deleted and created again reloads the new contents")
    func deleteThenRecreate() async throws {
        let live = try await Live()
        try FileManager.default.removeItem(at: live.file)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await live.store.current.error == ConfigError(.unreadable(errno: ENOENT)))
        try Data(ConfigTexts.valid("four").utf8).write(to: live.file)
        #expect(try await live.waitFor("four"))
        #expect(await live.store.current.error == nil)
        await live.store.stop()
    }

    /// Each watch holds two descriptors, the file and its directory; stopping has to give both back.
    @Test("starting and stopping twenty times leaves no descriptor open")
    func startStopReleasesDescriptors() async throws {
        let live = try await Live()
        await live.store.stop()
        // The kernel reports /private/var where Foundation says /var, and resolvingSymlinksInPath keeps /var.
        let resolved = try #require(realpath(live.directory.url.path(percentEncoded: false), nil))
        defer { free(resolved) }
        let inside = String(cString: resolved)
        for _ in 0..<20 {
            await live.store.start()
            #expect(Self.descriptors(under: inside) == 2)
            await live.store.stop()
        }
        var left = Self.descriptors(under: inside)
        for _ in 0..<100 where left > 0 {
            try await Task.sleep(for: .milliseconds(10))
            left = Self.descriptors(under: inside)
        }
        #expect(left == 0)
    }

    /// Open descriptors whose path is `directory` or inside it. Other suites run in parallel, so counting every
    /// descriptor in the process would measure them too.
    private static func descriptors(under directory: String) -> Int {
        let numbers = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return numbers.compactMap(Int32.init).filter { descriptor in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return false }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return path == directory || path.hasPrefix(directory + "/")
        }.count
    }

    /// vim's default save: write the new text to another name, then rename it over the original.
    @Test("a vim-style save through a temporary name reloads")
    func vimStyleSave() async throws {
        let live = try await Live()
        let swap = live.file.deletingLastPathComponent().appending(path: "commands.yaml~")
        try Data(ConfigTexts.valid("five").utf8).write(to: swap)
        _ = try FileManager.default.replaceItemAt(live.file, withItemAt: swap)
        #expect(try await live.waitFor("five"))
        await live.store.stop()
    }
}
