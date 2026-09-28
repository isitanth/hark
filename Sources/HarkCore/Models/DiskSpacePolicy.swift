import Foundation
import os

/// The free-space check that runs before the first byte of a download.
///
/// Capacity comes from `volumeAvailableCapacityForImportantUsage`, which counts what the system is willing to
/// purge for something the user is waiting on, so it reads larger than plain free space. The measurement is a
/// closure so tests can state a number instead of filling a disk.
public struct DiskSpacePolicy: Sendable {
    public typealias AvailableBytes = @Sendable (URL) -> Int64?

    public let availableBytes: AvailableBytes

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "disk-space")

    public init(availableBytes: @escaping AvailableBytes = DiskSpacePolicy.volumeCapacity) {
        self.availableBytes = availableBytes
    }

    public static let volumeCapacity: AvailableBytes = { url in
        // The models directory may not exist yet, and the answer is a property of the volume either way, so
        // walk up to the first parent that does.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path(percentEncoded: false)) {
            let parent = probe.deletingLastPathComponent()
            guard parent != probe else { return nil }
            probe = parent
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// A zip is charged twice: `ditto` writes the extracted tree beside the archive and only then is the
    /// archive deleted, so both exist at the high-water mark.
    public static func requiredBytes(for artifact: ModelArtifact) -> Int64 {
        artifact.isArchive ? artifact.byteCount * 2 : artifact.byteCount
    }

    public static func requiredBytes(for entry: ModelCatalogEntry) -> Int64 {
        entry.artifacts.reduce(0) { $0 + requiredBytes(for: $1) }
    }

    /// Nil when there is room. A volume that will not report its capacity is allowed through: refusing a
    /// download because the measurement failed is worse than letting the write run out of space and say so.
    public func check(_ required: Int64, at url: URL) -> ModelInstallFailure? {
        guard let available = availableBytes(url) else {
            Self.logger.warning("no capacity reading for \(url.path(percentEncoded: false), privacy: .public)")
            return nil
        }
        guard available < required else { return nil }
        Self.logger.error("need \(required) bytes, volume offers \(available)")
        return .insufficientSpace(required: required, available: available)
    }
}
