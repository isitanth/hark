import Foundation
import HarkCore
import Testing

/// commands.yaml texts for the store tests: one command whose app names the version.
enum ConfigTexts {
    static func valid(_ name: String) -> String {
        """
        version: 2
        commands:
          - id: "\(name)"
            action: open_app
            app: "\(name)"
        """
    }

    /// An unknown key on line 3, column 1.
    static let invalid = """
        version: 2
        commands: []
        bogus: true
        """

    static func config(_ name: String) throws -> CommandConfig {
        try CommandConfig.parse(Data(valid(name).utf8))
    }
}

/// A store over a fresh directory, a `ManualClock` and a `FakeFileWatcher`.
final class StoreHarness {
    let directory: TemporaryDirectory
    let file: URL
    let lastGood: URL
    let defaults: URL
    let clock = ManualClock()
    let watcher = FakeFileWatcher()
    let store: ConfigStore
    var snapshots: AsyncStream<ConfigSnapshot>.Iterator
    private var sleeps = 0

    init(withDefault: Bool = true) throws {
        directory = try TemporaryDirectory()
        let root = directory.url.appending(path: "Hark", directoryHint: .isDirectory)
        file = root.appending(path: "commands.yaml")
        lastGood = root.appending(path: ".commands.lastgood.yaml")
        defaults = directory.url.appending(path: "default-commands.yaml")
        try Data(ConfigTexts.valid("default").utf8).write(to: defaults)
        store = ConfigStore(
            fileURL: file, lastGoodURL: lastGood, defaultURL: withDefault ? defaults : nil, watcher: watcher,
            clock: clock)
        snapshots = store.snapshots.makeAsyncIterator()
    }

    func put(_ text: String, at url: URL? = nil) throws {
        let url = url ?? file
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic, so a debounce timer that wakes mid-write reads the old file or the new one, never half of one.
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func bytes(_ url: URL? = nil) -> Data? {
        try? Data(contentsOf: url ?? file)
    }

    /// One change noticed; returns once the store has started its debounce timer for it.
    func change() async {
        watcher.emit()
        sleeps += 1
        await clock.waitForSleeps(sleeps)
    }

    /// The next snapshot the store publishes.
    func next() async throws -> ConfigSnapshot {
        try #require(await snapshots.next())
    }
}

@Suite("Config hot reload")
struct ConfigHotReloadTests {
    @Test("first start seeds the file from the default, in a private directory")
    func seedsFromDefault() async throws {
        let harness = try StoreHarness()
        await harness.store.start()
        let first = try await harness.next()
        #expect(first.source == .file)
        #expect(first.error == nil)
        #expect(first.config == (try ConfigTexts.config("default")))
        #expect(harness.bytes() == harness.bytes(harness.defaults))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: harness.file.deletingLastPathComponent().path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o700)
        #expect(harness.watcher.watchedURLs == [harness.file])
    }

    @Test("start never overwrites an existing file")
    func keepsExistingFile() async throws {
        let harness = try StoreHarness()
        try harness.put(ConfigTexts.valid("mine"))
        await harness.store.start()
        let first = try await harness.next()
        #expect(first.config == (try ConfigTexts.config("mine")))
        #expect(harness.bytes() == Data(ConfigTexts.valid("mine").utf8))
    }

    @Test("an unedited version 1 default is replaced by the current default")
    func upgradesAnUntouchedRetiredDefault() async throws {
        let harness = try StoreHarness()
        try harness.put(String(decoding: try ConfigFixtures.data("commands-v1-default.yaml"), as: UTF8.self))
        await harness.store.start()
        let first = try await harness.next()
        #expect(first.source == .file && first.error == nil)
        #expect(first.config == (try ConfigTexts.config("default")))
        #expect(harness.bytes() == harness.bytes(harness.defaults))
    }

    @Test("the version 2 default M6.1 shipped, unedited, is replaced by the current one")
    func upgradesTheFirstVersion2Default() async throws {
        let harness = try StoreHarness()
        try harness.put(String(decoding: try ConfigFixtures.data("commands-v2-m6.1-default.yaml"), as: UTF8.self))
        await harness.store.start()
        let first = try await harness.next()
        #expect(first.source == .file && first.error == nil)
        #expect(harness.bytes() == harness.bytes(harness.defaults))
    }

    @Test("an edited version 1 file stays as it is and says which version it is")
    func keepsAnEditedRetiredDefault() async throws {
        let harness = try StoreHarness()
        let v1 = String(decoding: try ConfigFixtures.data("commands-v1-default.yaml"), as: UTF8.self)
        try harness.put(v1 + "# mine\n")
        await harness.store.start()
        let first = try await harness.next()
        #expect(first.error?.problem == .unsupportedVersion("1"))
        #expect(harness.bytes() == Data((v1 + "# mine\n").utf8))
    }

    @Test("a valid file is in force and copied byte for byte to the last good copy")
    func validFileWritesLastGood() async throws {
        let harness = try StoreHarness()
        try harness.put(ConfigTexts.valid("mine"))
        await harness.store.start()
        let first = try await harness.next()
        #expect(first.source == .file)
        #expect(first.diskRevision == ConfigRevision(of: Data(ConfigTexts.valid("mine").utf8)))
        #expect(harness.bytes(harness.lastGood) == Data(ConfigTexts.valid("mine").utf8))
    }

    @Test("start is idempotent")
    func startTwice() async throws {
        let harness = try StoreHarness()
        await harness.store.start()
        await harness.store.start()
        #expect(harness.watcher.watchedURLs.count == 1)
    }
}
