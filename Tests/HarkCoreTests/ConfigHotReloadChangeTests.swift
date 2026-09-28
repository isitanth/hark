import Foundation
import HarkCore
import Testing

/// The debounce and what a change on disk does to the config in force, on a `ManualClock` and a fake watcher.
@Suite("Config hot reload: changes")
struct ConfigHotReloadChangeTests {
    /// Started on a valid file, first snapshot consumed.
    private func started(_ phrase: String = "one") async throws -> StoreHarness {
        let harness = try StoreHarness()
        try harness.put(ConfigTexts.valid(phrase))
        await harness.store.start()
        _ = try await harness.next()
        return harness
    }

    @Test("three changes inside the window are one reload, of the final contents")
    func burstIsOneReload() async throws {
        let harness = try await started()
        for phrase in ["two", "three", "four"] {
            try harness.put(ConfigTexts.valid(phrase))
            await harness.change()
            harness.clock.advance(by: .milliseconds(40))
        }
        harness.clock.advance(by: .milliseconds(60))
        let reloaded = try await harness.next()
        #expect(reloaded.config == (try ConfigTexts.config("four")))
        #expect(harness.clock.sleeperCount == 0)
    }

    @Test("nothing reloads 99 ms after the last change, and it has at 100 ms")
    func debounceBoundary() async throws {
        let harness = try await started()
        try harness.put(ConfigTexts.valid("two"))
        await harness.change()
        harness.clock.advance(by: .milliseconds(99))
        #expect(await harness.store.current.config == (try ConfigTexts.config("one")))
        #expect(harness.clock.sleeperCount == 1)
        harness.clock.advance(by: .milliseconds(1))
        #expect(try await harness.next().config == (try ConfigTexts.config("two")))
    }

    @Test("a bad file keeps the config in force and says where, and fixing it recovers")
    func badFileThenFixed() async throws {
        let harness = try await started()
        try harness.put(ConfigTexts.invalid)
        await harness.change()
        harness.clock.advance(by: .milliseconds(100))
        let bad = try await harness.next()
        #expect(bad.source == .lastGood)
        #expect(bad.config == (try ConfigTexts.config("one")))
        #expect(
            bad.error == ConfigError(.unknownKey("bogus", path: "", suggestion: nil), at: .init(line: 3, column: 1)))
        #expect(bad.diskRevision == ConfigRevision(of: Data(ConfigTexts.invalid.utf8)))
        #expect(harness.bytes(harness.lastGood) == Data(ConfigTexts.valid("one").utf8))

        try harness.put(ConfigTexts.valid("fixed"))
        await harness.change()
        harness.clock.advance(by: .milliseconds(100))
        let fixed = try await harness.next()
        #expect(fixed.source == .file)
        #expect(fixed.error == nil)
        #expect(fixed.config == (try ConfigTexts.config("fixed")))
    }

    @Test("a cold start with a bad file uses the last good copy")
    func coldStartUsesLastGood() async throws {
        let harness = try StoreHarness()
        try harness.put(ConfigTexts.invalid)
        try harness.put(ConfigTexts.valid("previous"), at: harness.lastGood)
        await harness.store.start()
        let first = try await harness.next()
        #expect(first.source == .lastGood)
        #expect(first.config == (try ConfigTexts.config("previous")))
        #expect(first.error?.location == ConfigLocation(line: 3, column: 1))
    }

    @Test("a cold start with a bad file and no last good copy has no commands, never the bundled default")
    func coldStartWithNothing() async throws {
        let harness = try StoreHarness()
        try harness.put(ConfigTexts.invalid)
        await harness.store.start()
        let first = try await harness.next()
        #expect(first.source == .none)
        #expect(first.config == .empty)
        #expect(first.error != nil)
        #expect(harness.bytes(harness.lastGood) == nil)
    }

    /// Through `reload()`, which the debounce ends in, because awaiting it orders the reads: a timer woken by the clock
    /// could otherwise read the file while the test is still writing the next one.
    @Test("a reload that finds the bytes as they were publishes nothing")
    func unchangedBytes() async throws {
        let harness = try await started()
        await harness.store.reload()
        await harness.store.reload()
        try harness.put(ConfigTexts.valid("two"))
        await harness.store.reload()
        // The next snapshot is the real change, so the two no-ops published nothing in between.
        #expect(try await harness.next().config == (try ConfigTexts.config("two")))
    }

    @Test("a file deleted while running is ENOENT, keeps the config, and is not recreated")
    func deletedAtRuntime() async throws {
        let harness = try await started()
        try FileManager.default.removeItem(at: harness.file)
        await harness.change()
        harness.clock.advance(by: .milliseconds(100))
        let gone = try await harness.next()
        #expect(gone.error == ConfigError(.unreadable(errno: ENOENT)))
        #expect(gone.diskRevision == nil)
        #expect(gone.source == .lastGood)
        #expect(gone.config == (try ConfigTexts.config("one")))
        #expect(harness.bytes() == nil)
    }

    @Test("after stop, a change reloads nothing")
    func stopEndsWatching() async throws {
        let harness = try await started()
        await harness.store.stop()
        // The stream ends when the cancelled watch task next runs, so this is observed, not immediate.
        for _ in 0..<100 where harness.watcher.activeWatches > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.watcher.activeWatches == 0)
        try harness.put(ConfigTexts.valid("two"))
        harness.watcher.emit()
        harness.clock.advance(by: .seconds(1))
        #expect(await harness.store.current.config == (try ConfigTexts.config("one")))
    }
}
