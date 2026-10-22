import CoreGraphics
import Foundation
import HarkCore
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A synthetic capture: stripes, so PNG has something to compress, in `space`.
private func image(width: Int, height: Int, space: CFString = CGColorSpace.sRGB, noise: Bool = false) -> CGImage? {
    guard let colorSpace = CGColorSpace(name: space),
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    if noise, let pixels = context.data?.assumingMemoryBound(to: UInt32.self) {
        var seed: UInt32 = 2_463_534_242
        for index in 0..<(context.bytesPerRow / 4 * height) {
            seed ^= seed << 13
            seed ^= seed >> 17
            seed ^= seed << 5
            pixels[index] = seed | 0xFF00_0000
        }
    } else {
        for column in stride(from: 0, to: width, by: 8) {
            context.setFillColor(CGColor(srgbRed: column % 16 == 0 ? 1 : 0, green: 0.4, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: column, y: 0, width: 8, height: height))
        }
    }
    return context.makeImage()
}

private struct ReadBack {
    let width: Int
    let height: Int
    let type: String
    let colorSpace: String?
}

private func readBack(_ data: Data) throws -> ReadBack {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return ReadBack(
        width: decoded.width, height: decoded.height, type: CGImageSourceGetType(source) as String? ?? "",
        colorSpace: decoded.colorSpace?.name as String?)
}

@Suite struct RegionImageEncoderTests {
    @Test(arguments: [
        (1400, 1200, 2_576, 1400, 1200),
        (1400, 1200, 1_568, 1400, 1200),
        (3000, 1500, 1_568, 1568, 784),
        (1500, 3000, 2_576, 1288, 2576),
        (600, 240, 1_568, 600, 240),
        (5152, 2000, 2_576, 2576, 1000),
    ])
    func theTargetIsCappedOnTheLongEdgeAndNeverLarger(_ width: Int, _ height: Int, _ cap: Int, _ w: Int, _ h: Int) {
        let target = RegionImageEncoder.targetSize(width: width, height: height, cap: cap)
        #expect(target.width == w && target.height == h)
    }

    @Test func theCapFollowsTheDialect() {
        #expect(RegionImageEncoder.cap(for: .anthropic) == 2_576)
        #expect(RegionImageEncoder.cap(for: .openAI) == 1_568)
    }

    /// M11.0 measured the max-size key upscaling a 600×240 capture: an image under the cap keeps its exact size.
    @Test func anImageUnderTheCapKeepsItsExactSize() throws {
        let source = try #require(image(width: 600, height: 240))
        let encoded = try #require(RegionImageEncoder.encode(source, cap: 1_568))
        let back = try readBack(encoded.image.data)
        #expect(back.width == 600 && back.height == 240)
        #expect(encoded.pixelWidth == 600 && encoded.pixelHeight == 240)
        #expect(back.type == UTType.png.identifier && encoded.image.mediaType == "image/png")
        #expect(encoded.image.data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test func anImageOverTheCapIsScaledDownInTheSameCall() throws {
        let source = try #require(image(width: 3000, height: 1500))
        let encoded = try #require(RegionImageEncoder.encode(source, cap: 1_568))
        let back = try readBack(encoded.image.data)
        #expect(back.width == 1568 && back.height == 784)
        #expect(encoded.pixelWidth == 1568 && encoded.pixelHeight == 784)
    }

    /// Display P3 is converted, not relabelled: the bytes say sRGB.
    @Test(arguments: [CGColorSpace.sRGB as String, CGColorSpace.displayP3 as String])
    func theImageGoesInSRGB(_ space: String) throws {
        let source = try #require(image(width: 64, height: 32, space: space as CFString))
        let encoded = try #require(RegionImageEncoder.encode(source, cap: 1_568))
        #expect(try readBack(encoded.image.data).colorSpace == CGColorSpace.sRGB as String)
    }

    /// A photo-filled frame past the limit goes as JPEG; noise is the worst case for PNG.
    @Test func aFramePastTheLimitGoesAsJPEG() throws {
        let noisy = try #require(image(width: 2_576, height: 1_800, noise: true))
        let encoded = try #require(RegionImageEncoder.encode(noisy, cap: 2_576))
        #expect(encoded.image.mediaType == "image/jpeg")
        #expect(try readBack(encoded.image.data).type == UTType.jpeg.identifier)
        #expect(encoded.image.data.count <= RegionImageEncoder.jpegThreshold)
        #expect(encoded.pixelWidth == 2_576 && encoded.pixelHeight == 1_800)
    }
}
