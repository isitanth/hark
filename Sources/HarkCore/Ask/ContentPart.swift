import Foundation

/// One piece of a message: text, or the image of the region the user framed. A message of text alone is sent as a
/// plain string, byte for byte as before M11.
public enum ContentPart: Sendable, Equatable {
    case text(String)
    case image(ImagePart)
}

/// An encoded image, in memory only: never on disk, in the log or in an os_log line. Its description prints the byte
/// count, never the bytes.
public struct ImagePart: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var mediaType: String
    public var data: Data

    public init(mediaType: String = "image/png", data: Data) {
        self.mediaType = mediaType
        self.data = data
    }

    public var description: String { "ImagePart(\(mediaType), \(data.count) bytes)" }
    public var debugDescription: String { description }
}
