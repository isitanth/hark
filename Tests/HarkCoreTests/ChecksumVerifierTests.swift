import Foundation
import HarkCore
import Testing

@Suite struct ChecksumVerifierTests {
    private static let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private static let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func file(_ data: Data, in directory: TemporaryDirectory, named name: String = "artifact") throws -> URL {
        let url = directory.url.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url)
        return url
    }

    @Test func theStandardVectorsInMemory() {
        #expect(ChecksumVerifier.sha256(of: Data()) == Self.emptyHash)
        #expect(ChecksumVerifier.sha256(of: Data("abc".utf8)) == Self.abcHash)
    }

    @Test func theStandardVectorsFromDisk() throws {
        let directory = try TemporaryDirectory()
        #expect(try ChecksumVerifier.sha256(ofFileAt: file(Data(), in: directory, named: "empty")) == Self.emptyHash)
        #expect(
            try ChecksumVerifier.sha256(ofFileAt: file(Data("abc".utf8), in: directory, named: "abc"))
                == Self.abcHash)
    }

    /// Chunking is the whole point of the streamed path, so hash something that spans several windows and does
    /// not end on one, and check it against the one-shot digest of the same bytes.
    @Test func aFileLongerThanOneChunkHashesTheSameAsTheWholeThing() throws {
        let block = Data((0..<4096).map { UInt8(($0 &* 31 &+ 7) % 256) })
        var bytes = Data()
        while bytes.count < ChecksumVerifier.chunkSize * 2 {
            bytes.append(block)
        }
        bytes.append(Data("tail that makes the last read a short one".utf8))
        #expect(bytes.count % ChecksumVerifier.chunkSize != 0)

        let directory = try TemporaryDirectory()
        let url = try file(bytes, in: directory)
        #expect(try ChecksumVerifier.sha256(ofFileAt: url) == ChecksumVerifier.sha256(of: bytes))
    }

    @Test func oneFlippedByteChangesTheAnswer() throws {
        let directory = try TemporaryDirectory()
        let good = try file(Data("abc".utf8), in: directory, named: "good")
        let bad = try file(Data("abd".utf8), in: directory, named: "bad")
        #expect(try ChecksumVerifier.verify(fileAt: good, matches: Self.abcHash))
        #expect(try !ChecksumVerifier.verify(fileAt: bad, matches: Self.abcHash))
    }

    @Test func anUppercaseExpectationStillMatches() throws {
        let directory = try TemporaryDirectory()
        let url = try file(Data("abc".utf8), in: directory)
        #expect(try ChecksumVerifier.verify(fileAt: url, matches: Self.abcHash.uppercased()))
    }

    @Test func aMissingFileIsUnreadableRatherThanAHash() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "not-there", directoryHint: .notDirectory)
        #expect(throws: ChecksumFailure.self) {
            try ChecksumVerifier.sha256(ofFileAt: url)
        }
    }
}
