import CoreGraphics
import Foundation
import HarkCore
import Testing

struct GeometryCase: Sendable, CustomTestStringConvertible {
    let name: String
    let screen: CGRect
    let scale: CGFloat
    let start: CGPoint
    let end: CGPoint
    let expected: CaptureGeometry?

    var testDescription: String { name }
}

private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
/// This Mac's 1x MSI, above the built-in display.
private let msi = CGRect(x: -912, y: 982, width: 3440, height: 1440)

private func geometry(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, pixels: CGSize) -> CaptureGeometry {
    CaptureGeometry(sourceRect: CGRect(x: x, y: y, width: w, height: h), pixelSize: pixels)
}

let geometryCases: [GeometryCase] = [
    .init(
        name: "A. the Retina built-in display", screen: builtIn, scale: 2, start: CGPoint(x: 100, y: 800),
        end: CGPoint(x: 800, y: 200), expected: geometry(100, 182, 700, 600, pixels: CGSize(width: 1400, height: 1200))),
    .init(
        name: "B. a 1x display left of and above the primary",
        screen: CGRect(x: -1920, y: 300, width: 1920, height: 1080),
        scale: 1, start: CGPoint(x: -1500, y: 1200), end: CGPoint(x: -1100, y: 900),
        expected: geometry(420, 180, 400, 300, pixels: CGSize(width: 400, height: 300))),
    .init(
        name: "C. a drag onto the next display, clamped to the first", screen: builtIn, scale: 2,
        start: CGPoint(x: 1300, y: 600), end: CGPoint(x: 1800, y: 300),
        expected: geometry(1300, 382, 212, 300, pixels: CGSize(width: 424, height: 600))),
    .init(
        name: "this Mac's MSI, above the built-in display", screen: msi, scale: 1, start: CGPoint(x: -500, y: 2000),
        end: CGPoint(x: 300, y: 1500), expected: geometry(412, 422, 800, 500, pixels: CGSize(width: 800, height: 500))),
    .init(
        name: "dragged up from the MSI onto the built-in, clamped", screen: msi, scale: 1,
        start: CGPoint(x: 0, y: 1100), end: CGPoint(x: 200, y: 700),
        expected: geometry(912, 1322, 200, 118, pixels: CGSize(width: 200, height: 118))),
    .init(
        name: "half points snap outward to whole pixels", screen: builtIn, scale: 2,
        start: CGPoint(x: 10.3, y: 900.1), end: CGPoint(x: 60.6, y: 850.2),
        expected: geometry(10, 81.5, 51, 50.5, pixels: CGSize(width: 102, height: 101))),
    .init(
        name: "a click frames nothing", screen: builtIn, scale: 2, start: CGPoint(x: 400, y: 400),
        end: CGPoint(x: 400, y: 400), expected: nil),
    .init(
        name: "7 pt high is a click", screen: builtIn, scale: 2, start: CGPoint(x: 400, y: 400),
        end: CGPoint(x: 600, y: 407), expected: nil),
    .init(
        name: "8 pt is a frame", screen: builtIn, scale: 2, start: CGPoint(x: 400, y: 400),
        end: CGPoint(x: 408, y: 408), expected: geometry(400, 574, 8, 8, pixels: CGSize(width: 16, height: 16))),
    .init(
        name: "a drag wholly off its display", screen: builtIn, scale: 2, start: CGPoint(x: 1600, y: 400),
        end: CGPoint(x: 1800, y: 600), expected: nil),
]

@Suite struct CaptureGeometryTests {
    @Test(arguments: geometryCases)
    func aDragBecomesTheRectTheCaptureTakes(_ row: GeometryCase) {
        #expect(captureGeometry(start: row.start, end: row.end, screen: row.screen, scale: row.scale) == row.expected)
    }

    /// The pixel size is the source rect at the display's scale, exactly: no half pixel at an edge.
    @Test(arguments: geometryCases.compactMap(\.expected))
    func thePixelsAreWholeAndMatchTheRect(_ geometry: CaptureGeometry) {
        #expect(geometry.pixelSize.width == geometry.pixelSize.width.rounded())
        #expect(geometry.pixelSize.height == geometry.pixelSize.height.rounded())
    }
}
