import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A framed region's image, encoded in memory, and the size it went at.
public struct EncodedRegion: Sendable, Equatable {
    public let image: ImagePart
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(image: ImagePart, pixelWidth: Int, pixelHeight: Int) {
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// A captured region to PNG bytes, never a file: sRGB, its long edge capped per dialect, Retina pixels kept up to the
/// cap (small text needs them). JPEG ringing blurs small text, so JPEG only when a photo-filled frame passes the limit.
public enum RegionImageEncoder {
    /// Claude's high-resolution tier, on the long edge.
    public static let anthropicCap = 2_576
    /// The local server's cap (M11.0 kept it).
    public static let localCap = 1_568
    /// Above this many PNG bytes the image goes as JPEG at `jpegQuality`.
    public static let jpegThreshold = 9_000_000
    public static let jpegQuality = 0.9

    public static func cap(for api: ProviderAPI) -> Int {
        switch api {
        case .anthropic: anthropicCap
        case .openAI: localCap
        }
    }

    /// The size an image of `width` × `height` goes at: `scale = min(1, cap / longEdge)`, never larger.
    public static func targetSize(width: Int, height: Int, cap: Int) -> (width: Int, height: Int) {
        let longEdge = max(width, height)
        guard longEdge > cap, longEdge > 0 else { return (width, height) }
        let scale = Double(cap) / Double(longEdge)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// Nil when ImageIO cannot encode it: the capture's failure, `region_failed`.
    public static func encode(_ image: CGImage, cap: Int) -> EncodedRegion? {
        guard let srgb = inSRGB(image) else { return nil }
        // The max-size key upscales (measured in M11.0): set it only when the long edge is over the cap.
        var options: [CFString: Any] = [:]
        if max(srgb.width, srgb.height) > cap { options[kCGImageDestinationImageMaxPixelSize] = cap }
        guard let png = write(srgb, type: .png, options: options) else { return nil }
        var data = png
        var mediaType = "image/png"
        if png.count > jpegThreshold {
            options[kCGImageDestinationLossyCompressionQuality] = jpegQuality
            guard let jpeg = write(srgb, type: .jpeg, options: options) else { return nil }
            data = jpeg
            mediaType = "image/jpeg"
        }
        guard let size = pixelSize(of: data) else { return nil }
        return EncodedRegion(
            image: ImagePart(mediaType: mediaType, data: data), pixelWidth: size.width, pixelHeight: size.height)
    }

    private static func write(_ image: CGImage, type: UTType, options: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The image itself when it is sRGB already, as ScreenCaptureKit is asked for; otherwise drawn into sRGB, which
    /// converts it rather than relabelling it.
    private static func inSRGB(_ image: CGImage) -> CGImage? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        if let space = image.colorSpace, space.name == CGColorSpace.sRGB { return image }
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
