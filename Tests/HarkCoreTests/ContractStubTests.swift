import CoreGraphics
import Foundation
import HarkCore
import Testing

private typealias F = Fixture

/// What wave 1 relies on while the M13 contract's stubs stand. Each builder deletes the rows its bodies no longer
/// satisfy, in the commit that lands them.
@Suite struct ContractStubTests {
    @Test func theNullReaderFailsWithVision() async throws {
        let bitmap = try #require(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let raster = RegionRaster(image: try #require(bitmap.makeImage()))
        #expect(await NullRegionReader().read(raster) == .failure(.vision))
    }

    @Test func theNullPlannerFails() async {
        let sheet = CellSheet(cells: [], convention: .plain, readMs: 0)
        var events: [LLMEvent] = []
        for await event in NullAskPlanner().plan(
            instruction: "Total ?", sheet: sheet, selection: nil, image: nil, thread: nil, frames: [:],
            correction: nil)
        {
            events.append(event)
        }
        #expect(events == [.failed(.unreachable(host: ""), LLMCallSummary())])
    }

    /// On in the config, but the reducer stamps nothing until the app says so, which it does on macOS 26 and later.
    @Test func exactMathIsOnByDefaultAndWaitsForTheApp() {
        #expect(LLMConfig.standard.exactMath)
        #expect(!PipelineReducer().exactMath)
    }

    /// With exact math off nothing stamps an ask: every existing transition is today's.
    @Test(arguments: [
        F.capturing, F.transcribing, F.resolving, F.inserting, F.copying, F.acting, F.askCapturing, F.askTranscribing,
        F.generating, F.reviewing, F.awaitingRegion, F.regionAskFailed, F.assistGenerating, F.assistReviewing,
    ])
    func noFixtureCarriesExactMath(_ state: PipelineState) {
        #expect(state.context?.math == nil)
    }

    // M14.1's stubs. S1: the plan set, the engine over it, the stream, the result words. S3: the anchor, the change,
    // the zone search, the stillness detector. S4: the results' presentation. Each row goes with the body that lands.

    @Test func theStreamReadsNoResultYet() {
        #expect(PlanStream.understoods(partial: #"{"results":[{"understood":"Le total"#).isEmpty)
    }

    @Test func theResultWordsNameNone() {
        #expect(ResultWords.named(in: "le résultat deux moins le résultat un", count: 2).isEmpty)
        #expect(ResultWords.stripped("le résultat deux") == "le résultat deux")
    }

    @Test func noResultsArePresented() {
        #expect(AskPresentation.results(nil, locale: Locale(identifier: "en_US_POSIX")) == nil)
    }

    @Test func nothingIsAnchoredAndEveryPollIsGone() {
        let zone = CGRect(x: 10, y: 10, width: 100, height: 50)
        let window = AnchorCandidate(
            windowID: 7, ownerPID: 42, layer: 0, bounds: CGRect(x: 0, y: 0, width: 400, height: 300), onScreen: true)
        #expect(RegionAnchor.choose(zone: zone, windows: [window], harkPID: 1) == nil)
        #expect(AnchorChange.classify(old: zone, new: zone, onScreen: true) == .gone)
    }

    @Test func theZoneIsNeverFoundAndNothingIsStill() throws {
        let bitmap = try #require(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let image = try #require(bitmap.makeImage())
        let zone = CGRect(x: 0, y: 0, width: 1, height: 1)
        #expect(ZoneRegistration.find(reference: image, recapture: image, zone: zone, cells: [zone]) == .notFound)
        var detector = StillnessDetector()
        #expect(detector.record(InputRecord(kind: .scroll(momentumEnded: false), at: .zero)) == .none)
        #expect(detector.tick(at: .seconds(1)) == .none)
    }

    /// Not a stub: the contract's new defect, retried with its note.
    @Test func anUnknownResultIsRetriedWithItsNote() {
        #expect(PlanDefect.unknownResult.code == "unknown_result")
        #expect(PlanDefect.unknownResult.isRetryable)
        #expect(PlanDefect.unknownResult.correction == "refer only to result IDs from the results list")
        #expect(Formula.result(2).results == [2] && Formula.result(2).cells.isEmpty)
    }
}
