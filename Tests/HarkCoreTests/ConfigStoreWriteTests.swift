import Foundation
import HarkCore
import Testing

/// `ConfigStore.write`: the Settings UI's only way to change commands.yaml, refused whenever it would lose an edit.
@Suite("Config store writes")
struct ConfigStoreWriteTests {
    private func started(_ phrase: String = "one") async throws -> (StoreHarness, ConfigSnapshot) {
        let harness = try StoreHarness()
        try harness.put(ConfigTexts.valid(phrase))
        await harness.store.start()
        return (harness, try await harness.next())
    }

    @Test("a write based on the revision on disk replaces the file, the last good copy and the config in force")
    func writeOnCurrentRevision() async throws {
        let (harness, first) = try await started()
        try await harness.store.write(ConfigTexts.valid("two"), basedOn: first.diskRevision)
        let written = try await harness.next()
        let bytes = Data(ConfigTexts.valid("two").utf8)
        #expect(written.source == .file)
        #expect(written.error == nil)
        #expect(written.config == (try ConfigTexts.config("two")))
        #expect(written.diskRevision == ConfigRevision(of: bytes))
        #expect(harness.bytes() == bytes)
        #expect(harness.bytes(harness.lastGood) == bytes)
    }

    /// The echo is a debounced reload of the bytes just written; `reload()` is where that ends, awaited so the order
    /// is certain.
    @Test("the watcher's echo of the store's own write reloads nothing")
    func ownWriteEchoIsSilent() async throws {
        let (harness, first) = try await started()
        try await harness.store.write(ConfigTexts.valid("two"), basedOn: first.diskRevision)
        _ = try await harness.next()
        await harness.store.reload()
        try harness.put(ConfigTexts.valid("three"))
        await harness.store.reload()
        // Had the echo published, it would come first.
        #expect(try await harness.next().config == (try ConfigTexts.config("three")))
    }

    @Test("a write based on a revision the file has moved past is refused and changes nothing")
    func staleBaseIsAConflict() async throws {
        let (harness, first) = try await started()
        try harness.put(ConfigTexts.valid("edited in vim"))
        let onDisk = harness.bytes()
        await #expect(
            throws: ConfigWriteError.conflict(expected: first.diskRevision, found: onDisk.map(ConfigRevision.init))
        ) {
            try await harness.store.write(ConfigTexts.valid("from settings"), basedOn: first.diskRevision)
        }
        #expect(harness.bytes() == onDisk)
        #expect(await harness.store.current.config == (try ConfigTexts.config("one")))
    }

    @Test("a write that expects no file is refused when there is one")
    func nilBaseWithAFileIsAConflict() async throws {
        let (harness, first) = try await started()
        await #expect(throws: ConfigWriteError.conflict(expected: nil, found: first.diskRevision)) {
            try await harness.store.write(ConfigTexts.valid("two"), basedOn: nil)
        }
        #expect(harness.bytes() == Data(ConfigTexts.valid("one").utf8))
    }

    @Test("text that does not parse is refused before anything is written")
    func invalidTextIsRefused() async throws {
        let (harness, first) = try await started()
        let expected = ConfigError(.unknownKey("bogus", path: "", suggestion: nil), at: .init(line: 3, column: 1))
        await #expect(throws: ConfigWriteError.invalid(expected)) {
            try await harness.store.write(ConfigTexts.invalid, basedOn: first.diskRevision)
        }
        #expect(harness.bytes() == Data(ConfigTexts.valid("one").utf8))
        #expect(harness.bytes(harness.lastGood) == Data(ConfigTexts.valid("one").utf8))
    }

    @Test("a write keeps the file's permissions")
    func writeKeepsPermissions() async throws {
        let (harness, first) = try await started()
        let path = harness.file.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        try await harness.store.write(ConfigTexts.valid("two"), basedOn: first.diskRevision)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o640)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: harness.file.deletingLastPathComponent().path(percentEncoded: false))
        #expect(Set(leftovers) == [".commands.lastgood.yaml", "commands.yaml"])
    }

    /// The review's P0: a sheet opened before the file broke must not write the last good copy over the edit being
    /// fixed. The degraded snapshot names the broken file's revision, so the revision check alone would let it through.
    @Test("a file with an error is never written over, even on its own revision")
    func aBrokenFileIsNotWrittenOver() async throws {
        let (harness, _) = try await started()
        try harness.put(ConfigTexts.invalid)
        await harness.change()
        harness.clock.advance(by: .milliseconds(100))
        let broken = try await harness.next()
        #expect(broken.isDegraded)
        await #expect(throws: ConfigWriteError.degraded) {
            try await harness.store.write(ConfigTexts.valid("from settings"), basedOn: broken.diskRevision)
        }
        #expect(harness.bytes() == Data(ConfigTexts.invalid.utf8))
        #expect(harness.bytes(harness.lastGood) == Data(ConfigTexts.valid("one").utf8))
    }

    /// Nobody is editing a file that is not there, so it may be written again from what is in force.
    @Test("a deleted file can be written again")
    func aMissingFileCanBeWritten() async throws {
        let (harness, _) = try await started()
        try FileManager.default.removeItem(at: harness.file)
        await harness.change()
        harness.clock.advance(by: .milliseconds(100))
        let missing = try await harness.next()
        #expect(missing.isDegraded && missing.diskRevision == nil)
        try await harness.store.write(ConfigTexts.valid("two"), basedOn: nil)
        #expect(harness.bytes() == Data(ConfigTexts.valid("two").utf8))
    }

    /// commands.yaml kept in a dotfiles repository and linked into place stays a link, and the file it names is the
    /// one that changes.
    @Test("a write goes through a symlink to the file it names")
    func aSymlinkStaysALink() async throws {
        let harness = try StoreHarness()
        let real = harness.directory.url.appending(path: "dotfiles/commands.yaml")
        try harness.put(ConfigTexts.valid("one"), at: real)
        try FileManager.default.createDirectory(
            at: harness.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: harness.file, withDestinationURL: real)
        await harness.store.start()
        let first = try await harness.next()
        try await harness.store.write(ConfigTexts.valid("two"), basedOn: first.diskRevision)
        let path = harness.file.path(percentEncoded: false)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == real.path(percentEncoded: false))
        #expect(harness.bytes(real) == Data(ConfigTexts.valid("two").utf8))
    }

    /// A link into a repository that moved: the seed must not put a regular file where the link was, or the edits
    /// made in the repository once it is back would stop applying.
    @Test("a dangling symlink whose target folder is gone stays a link")
    func aDanglingLinkIsNotReplaced() async throws {
        let harness = try StoreHarness()
        try FileManager.default.createDirectory(
            at: harness.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let gone = harness.directory.url.appending(path: "moved-away/commands.yaml")
        try FileManager.default.createSymbolicLink(at: harness.file, withDestinationURL: gone)
        await harness.store.start()
        _ = try await harness.next()
        let path = harness.file.path(percentEncoded: false)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == gone.path(percentEncoded: false))
    }

    /// Eight links are followed; a ninth is refused as a loop, and the write fails without touching anything.
    @Test("a chain of eight links is followed and a ninth is refused", arguments: [(8, true), (9, false)])
    func aChainOfLinksHasALimit(_ links: Int, _ writes: Bool) async throws {
        let harness = try StoreHarness()
        let real = harness.directory.url.appending(path: "dotfiles/commands.yaml")
        try harness.put(ConfigTexts.valid("one"), at: real)
        try FileManager.default.createDirectory(
            at: harness.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var destination = real
        for hop in (1..<links).reversed() {
            let link = harness.directory.url.appending(path: "link-\(hop)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            destination = link
        }
        try FileManager.default.createSymbolicLink(at: harness.file, withDestinationURL: destination)
        await harness.store.start()
        let first = try await harness.next()
        if writes {
            try await harness.store.write(ConfigTexts.valid("two"), basedOn: first.diskRevision)
            #expect(harness.bytes(real) == Data(ConfigTexts.valid("two").utf8))
        } else {
            await #expect(throws: (any Error).self) {
                try await harness.store.write(ConfigTexts.valid("two"), basedOn: first.diskRevision)
            }
            #expect(harness.bytes(real) == Data(ConfigTexts.valid("one").utf8))
        }
        let path = harness.file.path(percentEncoded: false)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: path) == destination.path(percentEncoded: false))
    }

    /// A relative link, as `ln -s ../dotfiles/commands.yaml` makes, is resolved against its own folder.
    @Test("a relative symlink is followed from its own folder")
    func aRelativeLinkIsFollowed() async throws {
        let harness = try StoreHarness()
        let real = harness.directory.url.appending(path: "dotfiles/commands.yaml")
        try harness.put(ConfigTexts.valid("one"), at: real)
        try FileManager.default.createDirectory(
            at: harness.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: harness.file.path(percentEncoded: false), withDestinationPath: "../dotfiles/commands.yaml")
        await harness.store.start()
        let first = try await harness.next()
        try await harness.store.write(ConfigTexts.valid("two"), basedOn: first.diskRevision)
        #expect(harness.bytes(real) == Data(ConfigTexts.valid("two").utf8))
        let path = harness.file.path(percentEncoded: false)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == "../dotfiles/commands.yaml")
    }
}
