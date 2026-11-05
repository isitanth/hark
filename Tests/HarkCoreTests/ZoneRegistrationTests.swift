import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import HarkCore

/// Finding the framed zone again in a fresh capture of its window (c3b §4 to §8), on synthetic pages drawn in memory
/// with CoreText: never a file, never a screen.
@Suite struct ZoneRegistrationTests {
    private static let width = 900
    private static let height = 1_300
    private static let top = 80
    private static let rowHeight = 48
    private static let left = 48

    /// A page of `rows` text rows, its content moved by (dx, dy) pixels and its type scaled by `zoom`.
    private static func page(
        _ rows: [String], dx: Int = 0, dy: Int = 0, subpixel: CGFloat = 0, zoom: CGFloat = 1,
        edit: (row: Int, text: String)? = nil,
        width: Int = width, height: Int = height
    ) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldSmoothFonts(false)
        let font = CTFontCreateWithName("Menlo" as CFString, 26 * zoom, nil)
        let black = CGColor(gray: 0, alpha: 1)
        for (index, text) in rows.enumerated() {
            let shown = edit?.row == index ? edit?.text ?? text : text
            let string = NSAttributedString(
                string: shown,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): black,
                ])
            let line = CTLineCreateWithAttributedString(string)
            // Top-left coordinates, at 2x: the row's baseline sits 34 px below its top.
            let rowTop = (CGFloat(top + index * rowHeight)) * zoom + CGFloat(dy) + subpixel
            let baseline = rowTop + 34 * zoom
            context.textPosition = CGPoint(x: CGFloat(left) * zoom + CGFloat(dx), y: CGFloat(height) - baseline)
            CTLineDraw(line, context)
            // A rule under each row, as tables draw them.
            context.setFillColor(gray: 0.75, alpha: 1)
            context.fill(
                CGRect(
                    x: CGFloat(dx), y: CGFloat(height) - rowTop - CGFloat(rowHeight) * zoom,
                    width: CGFloat(width), height: 1))
        }
        return try #require(context.makeImage())
    }

    /// Distinct rows, a label and an amount each.
    private static let ledger: [String] = (0..<64).map { index in
        let amount = (index * 7_919 + 1_237) % 98_765
        return "Item \(String(format: "%03d", index))  \(amount / 100).\(String(format: "%02d", amount % 100))  EUR"
    }

    /// Rows one digit apart: the same text but for the row's last digit.
    private static let periodic: [String] = (0..<64).map { "Total amount  4812.5\($0 % 10)  EUR" }

    private static let identical: [String] = Array(repeating: "Total amount  4812.50  EUR", count: 64)

    /// Rows 10 to 14 of the page, and the amount of row 12 tinted.
    private static func zone(rows: ClosedRange<Int> = 10...14) -> CGRect {
        CGRect(
            x: 24, y: top + rows.lowerBound * rowHeight - 4, width: 760,
            height: (rows.upperBound - rows.lowerBound + 1) * rowHeight)
    }

    private static func cell(row: Int) -> CGRect {
        CGRect(x: left + 150, y: top + row * rowHeight, width: 200, height: rowHeight)
    }

    private static func find(
        _ reference: CGImage, _ recapture: CGImage, zone: CGRect = zone(), cells: [CGRect] = [cell(row: 12)]
    ) -> ZoneMatch {
        ZoneRegistration.find(reference: reference, recapture: recapture, zone: zone, cells: cells)
    }

    @Test(arguments: [0, 1, 3, 37, 120, 300])
    func aShiftedPageIsFoundAtItsShift(_ shift: Int) throws {
        let reference = try Self.page(Self.ledger)
        #expect(Self.find(reference, try Self.page(Self.ledger, dy: -shift)) == .found(CGVector(dx: 0, dy: -shift)))
        #expect(Self.find(reference, try Self.page(Self.ledger, dy: shift)) == .found(CGVector(dx: 0, dy: shift)))
    }

    @Test func aSidewaysShiftIsFound() throws {
        let reference = try Self.page(Self.ledger)
        #expect(Self.find(reference, try Self.page(Self.ledger, dx: 30, dy: -17)) == .found(CGVector(dx: 30, dy: -17)))
    }

    @Test func rowsOneDigitApartAreFoundAtTheRightRowOrAmbiguousNeverOneRowOff() throws {
        let reference = try Self.page(Self.periodic)
        let zone = Self.zone(rows: 18...22)
        let cells = [Self.cell(row: 20)]
        for rows in [-3, 3] {
            let shift = rows * Self.rowHeight
            let match = Self.find(reference, try Self.page(Self.periodic, dy: shift), zone: zone, cells: cells)
            #expect(match == .found(CGVector(dx: 0, dy: shift)) || match == .ambiguous)
            for wrong in [shift - Self.rowHeight, shift + Self.rowHeight] {
                #expect(match != .found(CGVector(dx: 0, dy: wrong)))
            }
        }
    }

    @Test func identicalRowsAreAmbiguous() throws {
        let reference = try Self.page(Self.identical)
        let recapture = try Self.page(Self.identical, dy: -Self.rowHeight)
        #expect(
            Self.find(reference, recapture, zone: Self.zone(rows: 18...22), cells: [Self.cell(row: 20)]) == .ambiguous)
    }

    @Test func anEditedCellIsNotFound() throws {
        let reference = try Self.page(Self.ledger)
        let recapture = try Self.page(Self.ledger, dy: -37, edit: (row: 12, text: "Item 012  913.06  EUR"))
        #expect(Self.find(reference, recapture) == .notFound)
    }

    @Test func aZoomedCopyIsNotFound() throws {
        let reference = try Self.page(Self.ledger)
        #expect(Self.find(reference, try Self.page(Self.ledger, zoom: 1.1)) == .notFound)
    }

    @Test func aBlankRecaptureIsNotFound() throws {
        let reference = try Self.page(Self.ledger)
        #expect(Self.find(reference, try Self.page([])) == .notFound)
    }

    /// c3b §8: a recapture of uniform noise, from a fixed generator, is never found.
    @Test func uniformNoiseIsNotFound() throws {
        let reference = try Self.page(Self.ledger)
        var state: UInt32 = 0x9E37_79B9
        var bytes = [UInt8](repeating: 0, count: Self.width * Self.height)
        for index in bytes.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let noise = try #require(
            CGImage(
                width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: Self.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #expect(Self.find(reference, noise) == .notFound)
    }

    @Test func aRecaptureSmallerThanTheZoneIsNotFound() throws {
        let reference = try Self.page(Self.ledger)
        #expect(Self.find(reference, try Self.page(Self.ledger, width: 300, height: 120)) == .notFound)
    }

    /// The zone's top 40 % above the recapture: the cells still in view decide.
    @Test func halfTheZoneOutOfViewIsFoundOnTheVisibleCells() throws {
        let reference = try Self.page(Self.ledger)
        let zone = Self.zone()
        let shift = -Int(zone.minY) - 2 * Self.rowHeight
        let recapture = try Self.page(Self.ledger, dy: shift)
        let cells = [Self.cell(row: 11), Self.cell(row: 13), Self.cell(row: 14)]
        #expect(Self.find(reference, recapture, zone: zone, cells: cells) == .found(CGVector(dx: 0, dy: shift)))
        let found = ZoneRegistration.candidates(reference: reference, recapture: recapture, zone: zone, cells: cells)
            .filter(\.passes)
        #expect(found.map(\.visibleCells) == [2])
    }

    @Test func aZoneMostlyOutOfViewIsNotFound() throws {
        let reference = try Self.page(Self.ledger)
        let zone = Self.zone()
        let shift = -Int(zone.minY) - 4 * Self.rowHeight
        let recapture = try Self.page(Self.ledger, dy: shift)
        #expect(Self.find(reference, recapture, zone: zone, cells: [Self.cell(row: 14)]) == .notFound)
    }

    @Test func noCellOrAZoneTooSmallFindsNothing() throws {
        let reference = try Self.page(Self.ledger)
        #expect(Self.find(reference, reference, cells: []) == .notFound)
        #expect(Self.find(reference, reference, zone: CGRect(x: 24, y: 560, width: 12, height: 200)) == .notFound)
        #expect(Self.find(reference, reference, zone: CGRect(x: 800, y: 560, width: 200, height: 200)) == .notFound)
    }

    @Test func theSameInputsGiveTheSameAnswer() throws {
        let reference = try Self.page(Self.periodic)
        let recapture = try Self.page(Self.periodic, dy: 3 * Self.rowHeight)
        let zone = Self.zone(rows: 18...22)
        let cells = [Self.cell(row: 20)]
        let first = ZoneRegistration.candidates(reference: reference, recapture: recapture, zone: zone, cells: cells)
        let second = ZoneRegistration.candidates(reference: reference, recapture: recapture, zone: zone, cells: cells)
        #expect(first == second)
        #expect(
            Self.find(reference, recapture, zone: zone, cells: cells)
                == Self.find(
                    reference, recapture, zone: zone, cells: cells))
    }

    /// Antialiasing differs half a pixel away: still found, a pixel either side, within the measured MAD.
    @Test func aHalfPixelShiftIsStillFound() throws {
        let reference = try Self.page(Self.ledger)
        let recapture = try Self.page(Self.ledger, dy: 40, subpixel: 0.5)
        let match = Self.find(reference, recapture)
        #expect(match == .found(CGVector(dx: 0, dy: 40)) || match == .found(CGVector(dx: 0, dy: 41)))
    }

    // MARK: - A band too small to show the zone (M14.7, Stage Manager)

    /// M14.7's frame (781 × 252 pt) can be found in a band of its 985 × 825 pt window; not in the strip thumbnail the
    /// window server and ScreenCaptureKit gave for that window under Stage Manager (110 × 157 pt), nor in an empty band.
    @Test func theStripThumbnailCannotShowTheZone() {
        let zone = CGSize(width: 781, height: 252)
        #expect(ZoneRegistration.canFind(zoneSize: zone, inBandOf: CGSize(width: 985, height: 825)))
        #expect(!ZoneRegistration.canFind(zoneSize: zone, inBandOf: CGSize(width: 110, height: 157)))
        #expect(!ZoneRegistration.canFind(zoneSize: zone, inBandOf: .zero))
    }

    /// Exactly half the zone at best is the search's own floor: found; just under half is not.
    @Test func halfTheZoneAtBestIsTheFloor() {
        let zone = CGSize(width: 400, height: 200)
        #expect(ZoneRegistration.canFind(zoneSize: zone, inBandOf: CGSize(width: 200, height: 900)))
        #expect(ZoneRegistration.canFind(zoneSize: zone, inBandOf: CGSize(width: 900, height: 100)))
        #expect(!ZoneRegistration.canFind(zoneSize: zone, inBandOf: CGSize(width: 199, height: 900)))
        #expect(!ZoneRegistration.canFind(zoneSize: zone, inBandOf: CGSize(width: 900, height: 99)))
    }

    /// A band cut on both sides multiplies the cuts: 0.75 × 0.75 of the zone is still enough, 0.7 × 0.7 is not.
    @Test func cutsOnBothSidesMultiply() {
        let zone = CGSize(width: 400, height: 200)
        #expect(ZoneRegistration.canFind(zoneSize: zone, inBandOf: CGSize(width: 300, height: 150)))
        #expect(!ZoneRegistration.canFind(zoneSize: zone, inBandOf: CGSize(width: 280, height: 140)))
    }

    /// The template is the part of the frame that lay on the window: a 900 pt frame with 540 pt on its window keeps a
    /// 540 pt template, which a 400 pt band can still show at 74 %, where the whole frame would not.
    @Test func theTemplateNotTheWholeFrameIsMeasured() {
        let band = CGSize(width: 400, height: 825)
        #expect(ZoneRegistration.canFind(zoneSize: CGSize(width: 540, height: 200), inBandOf: band))
        #expect(!ZoneRegistration.canFind(zoneSize: CGSize(width: 900, height: 200), inBandOf: band))
    }

    /// A small zone in a thumbnail-sized band can be shown whole: the search runs there, as before.
    @Test func aSmallZoneFitsASmallBand() {
        let thumbnail = CGSize(width: 110, height: 157)
        #expect(ZoneRegistration.canFind(zoneSize: CGSize(width: 90, height: 80), inBandOf: thumbnail))
    }

    /// No zone can never be found.
    @Test func anEmptyZoneCannotBeFound() {
        let band = CGSize(width: 985, height: 825)
        #expect(!ZoneRegistration.canFind(zoneSize: .zero, inBandOf: band))
        #expect(!ZoneRegistration.canFind(zoneSize: CGSize(width: 0, height: 50), inBandOf: band))
    }
}
