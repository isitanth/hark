import CoreGraphics
import Foundation

/// What the pipeline keeps of a framed region: where it was and what went. Never its pixels: those stay in the
/// controller's private slot until the ask ends, so a snapshot copied to the UI carries a few numbers.
public struct RegionSummary: Sendable, Equatable {
    /// In the display's own points, top-left origin, as the capture asked for it.
    public var rect: CGRect
    /// The encoded image's size, after the cap.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// The encoded image's length.
    public var bytes: Int
    /// `CGDirectDisplayID` of the display the drag began on.
    public var displayID: UInt32

    public init(rect: CGRect, pixelWidth: Int, pixelHeight: Int, bytes: Int, displayID: UInt32) {
        self.rect = rect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bytes = bytes
        self.displayID = displayID
    }
}

/// Why a framed region did not become an image.
public enum RegionFailure: Sendable, Equatable {
    /// Hark has no Screen Recording grant.
    case screenRecordingDenied
    /// ScreenCaptureKit or the encoder failed.
    case captureFailed

    /// The log's code for it.
    public var pipelineFailure: PipelineFailure {
        switch self {
        case .screenRecordingDenied: .screenRecordingDenied
        case .captureFailed: .regionFailed
        }
    }
}
