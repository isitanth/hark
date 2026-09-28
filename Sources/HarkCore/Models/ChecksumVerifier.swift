import CryptoKit
import Foundation

public enum ChecksumFailure: Error, Sendable, Equatable {
    /// The file could not be opened or read. The string is for the log, not for the user.
    case unreadable(String)
}

/// SHA-256 over a file, in chunks.
///
/// The large-v3 weights are a gigabyte and the encoder zip is another: reading either into a `Data` to hash it
/// would cost that much resident memory on a machine that is about to load a model. So the digest is fed a
/// window at a time and the peak footprint stays at `chunkSize`.
public enum ChecksumVerifier {
    /// 1 MiB: about a thousand reads for the biggest artefact, and a peak that does not register.
    public static let chunkSize = 1 << 20

    public static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    public static func sha256(ofFileAt url: URL) throws(ChecksumFailure) -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                digest.update(data: chunk)
            }
            return hex(digest.finalize())
        } catch let failure as ChecksumFailure {
            throw failure
        } catch {
            throw .unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// True when the file hashes to `expected`. Both sides are compared as lowercase hex.
    public static func verify(fileAt url: URL, matches expected: String) throws(ChecksumFailure) -> Bool {
        try sha256(ofFileAt: url) == expected.lowercased()
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
