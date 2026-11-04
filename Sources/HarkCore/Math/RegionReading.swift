import CoreGraphics
import Foundation

// The reader's seam (M13). S2 owns this file after the contract; `VisionRegionReader` implements it.

/// The framed region at the display's own resolution, in memory only. Never in the state, a snapshot, an effect or
/// the log: the controller alone holds it, as long as its frame. Its description prints the size, never the pixels.
public struct RegionRaster: Sendable, CustomStringConvertible {
    public let image: CGImage
    /// The anchored window alone at the frame, in grey (M14): the reference `ZoneRegistration` finds the zone in
    /// again. In memory as long as the frame, freed with it; nil without an anchor.
    public let windowReference: CGImage?

    public init(image: CGImage, windowReference: CGImage? = nil) {
        self.image = image
        self.windowReference = windowReference
    }

    public var description: String { "RegionRaster(\(image.width) × \(image.height) px)" }
}

/// Why the reader gave no sheet. A frame with no number is not one: it takes today's path.
public enum ReaderFailure: String, Error, Sendable, CaseIterable {
    case vision
    /// Past 60 s.
    case timeout
}

/// Reads a framed region into cells, on this Mac.
public protocol RegionReading: Sendable {
    func read(_ raster: RegionRaster) async -> Result<CellSheet, ReaderFailure>
    /// Loads the reader's models ahead of a read: when ⌃⌥ arms framing, never at launch.
    func prewarm() async
}

/// Fails every read, for environments without a reader: macOS before 26, tests that never read.
public struct NullRegionReader: RegionReading {
    public init() {}

    public func read(_ raster: RegionRaster) async -> Result<CellSheet, ReaderFailure> {
        .failure(.vision)
    }

    public func prewarm() async {}
}
