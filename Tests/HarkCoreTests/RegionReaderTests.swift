import CoreGraphics
import Foundation
import Testing

@testable import HarkCore

@Suite struct RegionReaderTests {
    private let none: SheetBuilder.AmountSplitter = { _ in [] }

    @available(macOS 26, *)
    private func reader(_ recognizer: ScriptedRecognizer, clock: ManualClock = ManualClock()) -> VisionRegionReader {
        VisionRegionReader(recognizer: recognizer, amounts: none, clock: clock)
    }

    private func raster(_ width: Int = 400, _ height: Int = 300) throws -> RegionRaster {
        RegionRaster(image: try blankImage(width: width, height: height))
    }

    @available(macOS 26, *)
    @Test func aReadGivesTheBuildersSheet() async throws {
        let fixture = try ReaderFixture.load("c08-receipt-fr-tva20")
        let result = await reader(ScriptedRecognizer(fixture.document)).read(try raster())
        let sheet = try result.get()
        let built = await SheetBuilder.build(fixture.document, amounts: none) { boxes, _ in
            boxes.map { _ in "" }
        }
        #expect(sheet.cells == built.sheet.cells)
        #expect(sheet.cells.count == fixture.expected.cells.count)
    }

    @available(macOS 26, *)
    @Test func twoReadsRunOneAfterTheOther() async throws {
        let recognizer = ScriptedRecognizer(documentPause: .milliseconds(50))
        let reader = reader(recognizer)
        let image = try raster()
        async let first = reader.read(image)
        async let second = reader.read(image)
        _ = await (first, second)
        #expect(recognizer.events == ["start", "end", "start", "end"])
    }

    @available(macOS 26, *)
    @Test func aCancelledReadAsksNoCrop() async throws {
        let fixture = try ReaderFixture.load("c08-receipt-fr-tva20")
        let recognizer = ScriptedRecognizer(fixture.document, cancelAfterDocument: true)
        let image = try raster()
        let result = await Task { await reader(recognizer).read(image) }.value
        #expect(recognizer.calls.map(\.kind) == ["document"])
        #expect(try result.get().cells.isEmpty)
    }

    @available(macOS 26, *)
    @Test func aFailedDocumentRequestIsAVisionFailure() async throws {
        let result = await reader(ScriptedRecognizer(failDocument: true)).read(try raster())
        #expect(result == .failure(.vision))
    }

    @available(macOS 26, *)
    @Test func aFailedCropKeepsTheDocumentTextAndMarksTheCell() async throws {
        let fixture = try ReaderFixture.load("c02-invoices-fr-unpaid")
        let recognizer = ScriptedRecognizer(fixture.document, failLines: true)
        let sheet = try await reader(recognizer).read(try raster()).get()
        #expect(sheet.cells.count == fixture.expected.cells.count)
        #expect(sheet.cells.contains { $0.suspicious })
        #expect(recognizer.calls.contains { $0.kind == "accurate" })
    }

    @available(macOS 26, *)
    @Test(arguments: [(6000, 1000, 4096, 683), (2000, 1000, 2000, 1000), (1000, 5000, 819, 4096)])
    func theInputIsCapped(width: Int, height: Int, readWidth: Int, readHeight: Int) async throws {
        let recognizer = ScriptedRecognizer()
        _ = await reader(recognizer).read(try raster(width, height))
        #expect(recognizer.calls == [.init(kind: "document", width: readWidth, height: readHeight)])
    }

    @available(macOS 26, *)
    @Test func aWarmUpReadsRenderedTextOncePerTenMinutes() async throws {
        let clock = ManualClock()
        let recognizer = ScriptedRecognizer()
        let reader = reader(recognizer, clock: clock)
        await reader.prewarm()
        #expect(recognizer.calls.map(\.kind) == ["document", "accurate", "fast"])
        #expect(recognizer.calls.allSatisfy { $0.width == 240 && $0.height == 64 })
        clock.advance(by: .seconds(599))
        await reader.prewarm()
        #expect(recognizer.calls.count == 3)
        clock.advance(by: .seconds(2))
        await reader.prewarm()
        #expect(recognizer.calls.count == 6)
    }

    @available(macOS 26, *)
    @Test func aReadCountsAsWarm() async throws {
        let recognizer = ScriptedRecognizer()
        let reader = reader(recognizer)
        _ = await reader.read(try raster())
        await reader.prewarm()
        #expect(recognizer.calls.map(\.kind) == ["document"])
    }

    @available(macOS 26, *)
    @Test func theWarmUpImageHoldsText() throws {
        let image = try #require(VisionRegionReader.warmUpImage())
        #expect(image.width == 240 && image.height == 64)
    }

    @available(macOS 26, *)
    @Test func aFrameWithNothingIsAnEmptySheetNotAFailure() async throws {
        let sheet = try await reader(ScriptedRecognizer()).read(try raster()).get()
        #expect(sheet.cells.isEmpty)
    }

    @available(macOS 26, *)
    @Test func theNullReaderFailsAndReadsNothing() async throws {
        let reader = NullRegionReader()
        let image = try raster()
        #expect(await reader.read(image) == .failure(.vision))
        await reader.prewarm()
    }

    @available(macOS 26, *)
    @Test func thisMacGetsTheVisionReader() {
        #expect(RegionReaders.available)
        #expect(RegionReaders.make() is VisionRegionReader)
    }

    @available(macOS 26, *)
    @Test(arguments: [
        ([("1", 0.1, 0.4), ("2", 0.5, 0.4)], "1 2"),
        ([("b", 0.5, 0.4), ("a", 0.1, 0.4)], "a b"),
        ([("edge", 0.1, 0.0), ("mid", 0.2, 0.4)], "mid"),
        ([("top", 0.1, 0.0), ("bottom", 0.2, 0.85)], "top bottom"),
    ])
    func aCropKeepsItsMiddleObservationsLeftToRight(observations: [(String, Double, Double)], text: String) {
        let lines = observations.map { RawLine(text: $0.0, box: CGRect(x: $0.1, y: $0.2, width: 0.1, height: 0.2)) }
        #expect(VisionRegionReader.text(of: lines) == text)
    }
}
