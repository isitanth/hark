import CoreGraphics
import Foundation
import HarkCore
import Testing

/// The window a frame was drawn on, and how a poll of it reads (plan §4.5, c3a §2 to §4).
@Suite struct RegionAnchorTests {
    private static let hark: Int32 = 1
    private static let zone = CGRect(x: 100, y: 100, width: 200, height: 100)
    private static let dock = Int(CGWindowLevelForKey(.dockWindow))
    private static let floating = Int(CGWindowLevelForKey(.floatingWindow))

    private static func window(
        _ id: UInt32, _ bounds: CGRect, pid: Int32 = 42, layer: Int = 0, onScreen: Bool = true
    ) -> AnchorCandidate {
        AnchorCandidate(windowID: id, ownerPID: pid, layer: layer, bounds: bounds, onScreen: onScreen)
    }

    private static func choose(_ windows: [AnchorCandidate]) -> RegionAnchor? {
        RegionAnchor.choose(zone: zone, windows: windows, harkPID: hark)
    }

    @Test func aZoneWhollyOnOneWindowIsAnchoredToIt() throws {
        let anchor = try #require(Self.choose([Self.window(7, CGRect(x: 40, y: 60, width: 800, height: 600))]))
        #expect(anchor.windowID == 7 && anchor.ownerPID == 42 && anchor.layer == 0)
        #expect(anchor.windowBounds == CGRect(x: 40, y: 60, width: 800, height: 600))
        #expect(anchor.offset == CGPoint(x: 60, y: 40))
        #expect(anchor.size == CGSize(width: 200, height: 100))
        #expect(anchor.coverage == 1)
    }

    @Test func halfOnAWindowIsExactlyTheFloorAndPicked() throws {
        let anchor = try #require(Self.choose([Self.window(7, CGRect(x: 0, y: 0, width: 200, height: 600))]))
        #expect(anchor.windowID == 7)
        #expect(anchor.coverage == 0.5)
        #expect(anchor.offset == CGPoint(x: 100, y: 100))
    }

    @Test func justUnderHalfAnchorsNothing() {
        #expect(Self.choose([Self.window(7, CGRect(x: 0, y: 0, width: 199, height: 600))]) == nil)
    }

    @Test func fortySixtyAcrossTwoWindowsTakesTheSixty() throws {
        let left = Self.window(7, CGRect(x: 0, y: 0, width: 180, height: 600))
        let right = Self.window(8, CGRect(x: 180, y: 0, width: 600, height: 600))
        let anchor = try #require(Self.choose([left, right]))
        #expect(anchor.windowID == 8)
        #expect(abs(anchor.coverage - 0.6) < 1e-9)
        #expect(anchor.offset == CGPoint(x: -80, y: 100))
    }

    @Test func aTieGoesToTheFrontmost() throws {
        let left = Self.window(7, CGRect(x: 0, y: 0, width: 200, height: 600))
        let right = Self.window(8, CGRect(x: 200, y: 0, width: 600, height: 600))
        #expect(try #require(Self.choose([left, right])).windowID == 7)
        #expect(try #require(Self.choose([right, left])).windowID == 8)
    }

    @Test func aWindowAboveHidesPartOfTheZone() throws {
        let above = Self.window(9, CGRect(x: 100, y: 100, width: 60, height: 100))
        let below = Self.window(7, CGRect(x: 0, y: 0, width: 800, height: 600))
        let anchor = try #require(Self.choose([above, below]))
        #expect(anchor.windowID == 7)
        #expect(abs(anchor.coverage - 0.7) < 1e-9)
    }

    @Test func aWindowAboveHidingMostOfTheZoneLeavesTooLittle() throws {
        let above = Self.window(9, CGRect(x: 100, y: 100, width: 140, height: 100))
        let below = Self.window(7, CGRect(x: 0, y: 0, width: 800, height: 600))
        let anchor = try #require(Self.choose([above, below]))
        #expect(anchor.windowID == 9)
        #expect(abs(anchor.coverage - 0.7) < 1e-9)
    }

    @Test func theDocksFullScreenWindowHidesNothing() throws {
        let dock = Self.window(3, CGRect(x: 0, y: 0, width: 1728, height: 1117), pid: 77, layer: Self.dock)
        let below = Self.window(7, CGRect(x: 0, y: 0, width: 800, height: 600))
        let anchor = try #require(Self.choose([dock, below]))
        #expect(anchor.windowID == 7 && anchor.coverage == 1)
    }

    @Test func aFloatingPanelOverTheZoneAnchorsNothing() {
        let panel = Self.window(5, CGRect(x: 50, y: 50, width: 400, height: 300), pid: 88, layer: Self.floating)
        let below = Self.window(7, CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(Self.choose([panel, below]) == nil)
        #expect(Self.choose([panel]) == nil)
    }

    @Test func harksOwnPanelInFrontIsLeftOut() throws {
        let panel = Self.window(2, CGRect(x: 0, y: 0, width: 800, height: 600), pid: Self.hark, layer: 0)
        let below = Self.window(7, CGRect(x: 0, y: 0, width: 800, height: 600))
        let anchor = try #require(Self.choose([panel, below]))
        #expect(anchor.windowID == 7 && anchor.coverage == 1)
        #expect(Self.choose([panel]) == nil)
    }

    @Test func anOffScreenWindowIsSkipped() throws {
        let hidden = Self.window(6, CGRect(x: 0, y: 0, width: 800, height: 600), onScreen: false)
        let below = Self.window(7, CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(try #require(Self.choose([hidden, below])).windowID == 7)
        #expect(Self.choose([hidden]) == nil)
    }

    @Test func noWindowAnchorsNothing() {
        #expect(Self.choose([]) == nil)
    }

    // MARK: - The change

    private static let old = CGRect(x: 40, y: 60, width: 800, height: 600)

    @Test func aWindowNoLongerListedIsGone() {
        #expect(AnchorChange.classify(old: Self.old, new: nil, onScreen: true) == .gone)
        #expect(AnchorChange.classify(old: Self.old, new: nil, onScreen: false) == .gone)
    }

    @Test func aWindowNotOnScreenIsOffscreen() {
        #expect(AnchorChange.classify(old: Self.old, new: Self.old, onScreen: false) == .offscreen)
    }

    @Test(arguments: [
        (CGRect(x: 40, y: 60, width: 800, height: 600), AnchorChange.still),
        (CGRect(x: 40.25, y: 59.75, width: 800.25, height: 599.75), .still),
        (CGRect(x: 40, y: 60, width: 800.26, height: 600), .resized),
        (CGRect(x: 40, y: 60, width: 800, height: 599.74), .resized),
        (CGRect(x: 90, y: 10, width: 801, height: 600), .resized),
        (CGRect(x: 40.5, y: 60, width: 800, height: 600), .moved(CGVector(dx: 0.5, dy: 0))),
        (CGRect(x: 40, y: 59.5, width: 800, height: 600), .moved(CGVector(dx: 0, dy: -0.5))),
        (CGRect(x: 140, y: 30, width: 800.25, height: 600), .moved(CGVector(dx: 100, dy: -30))),
    ])
    func aPollIsClassifiedAtAQuarterPoint(_ new: CGRect, _ change: AnchorChange) {
        #expect(AnchorChange.classify(old: Self.old, new: new, onScreen: true) == change)
    }

    // MARK: - Shrunk to a thumbnail (M14.7, Stage Manager)

    private static let framed = CGSize(width: 985, height: 825)

    /// Stage Manager lists a minimised window at its strip thumbnail: 985 × 825 pt became 110 × 157 pt.
    @Test func theStripThumbnailIsAShrinkToAThumbnail() {
        #expect(AnchorChange.shrankToAThumbnail(from: Self.framed, to: CGSize(width: 110, height: 157)))
    }

    /// A small window shrinks to a thumbnail too: the strip's size does not depend on the window's.
    @Test func aSmallWindowShrinksToAThumbnailToo() {
        let small = CGSize(width: 480, height: 300)
        #expect(AnchorChange.shrankToAThumbnail(from: small, to: CGSize(width: 110, height: 157)))
    }

    /// The bound is the thumbnail side, inclusive.
    @Test func theThumbnailSideIsInclusive() {
        #expect(AnchorChange.shrankToAThumbnail(from: Self.framed, to: CGSize(width: 200, height: 200)))
        #expect(!AnchorChange.shrankToAThumbnail(from: Self.framed, to: CGSize(width: 201, height: 150)))
        #expect(!AnchorChange.shrankToAThumbnail(from: Self.framed, to: CGSize(width: 150, height: 201)))
    }

    /// A window framed smaller than its thumbnail on one side still shrinks to one: the strip skews it, so it is
    /// smaller on the other side only.
    @Test func aWindowSmallerThanItsThumbnailOnOneSideStillShrinksToOne() {
        let tiny = CGSize(width: 150, height: 150)
        #expect(AnchorChange.shrankToAThumbnail(from: tiny, to: CGSize(width: 110, height: 157)))
    }

    /// A zoom back, a tile or a resize by hand leaves a larger window; a window that did not shrink, or grew, is none.
    @Test(arguments: [
        (CGSize(width: 1_500, height: 900), CGSize(width: 740, height: 440)),
        (Self.framed, CGSize(width: 380, height: 400)),
        (Self.framed, CGSize(width: 350, height: 825)),
        (CGSize(width: 180, height: 180), CGSize(width: 180, height: 180)),
        (CGSize(width: 110, height: 157), Self.framed),
        (CGSize(width: 110, height: 157), CGSize(width: 120, height: 160)),
    ])
    func otherSizeChangesAreNoThumbnail(_ old: CGSize, _ new: CGSize) {
        #expect(!AnchorChange.shrankToAThumbnail(from: old, to: new))
    }

    // MARK: - The note for a miss (M14.7)

    /// Once drawn, a window shrunk to a thumbnail ends without a note, as a minimise does.
    @Test func aDrawnLayerOnAThumbnailEndsSilently() {
        #expect(LayerNote.miss(framedWindow: Self.framed, window: CGSize(width: 110, height: 157), drawn: true) == nil)
    }

    /// Before the first draw, or on a window of any other size, a miss says so.
    @Test(arguments: [
        (CGSize(width: 110, height: 157), false), (Self.framed, true), (CGSize(width: 740, height: 440), true),
        (Self.framed, false),
    ])
    func otherMissesSaySo(_ window: CGSize, _ drawn: Bool) {
        #expect(LayerNote.miss(framedWindow: Self.framed, window: window, drawn: drawn) == .notFound)
    }

    // MARK: - Off screen, or closing (M14.7)

    private static func ms(_ value: Int) -> Duration { .milliseconds(value) }

    /// A window no longer listed is closed at once, whether or not a poll saw it off screen first.
    @Test func aWindowNoLongerListedIsClosedAtOnce() {
        var watch = OffscreenWatch()
        #expect(watch.observe(.gone, at: Self.ms(0)) == .closed)
    }

    /// Preview's close, as measured: off screen for about 275 ms, then dropped. The watch says closed, not off screen.
    @Test func aCloseSeenOffScreenFirstIsClosed() {
        var watch = OffscreenWatch()
        #expect(watch.observe(.offscreen, at: Self.ms(0)) == .waiting)
        #expect(watch.observe(.offscreen, at: Self.ms(100)) == .waiting)
        #expect(watch.observe(.offscreen, at: Self.ms(200)) == .waiting)
        #expect(watch.observe(.gone, at: Self.ms(300)) == .closed)
    }

    /// Off screen for the whole grace, still listed: minimised, hidden or on another Space.
    @Test func offScreenForTheWholeGraceIsOffscreen() {
        var watch = OffscreenWatch()
        #expect(watch.observe(.offscreen, at: Self.ms(1_000)) == .waiting)
        #expect(watch.observe(.offscreen, at: Self.ms(1_599)) == .waiting)
        #expect(watch.observe(.offscreen, at: Self.ms(1_600)) == .offscreen)
    }

    /// The grace outlasts the measured close with room to spare.
    @Test func theGraceOutlastsTheMeasuredClose() {
        #expect(OffscreenWatch.grace >= Self.ms(2 * 275))
    }

    /// Back on screen within the grace: look for the zone again, once; later polls say nothing.
    @Test(arguments: [AnchorChange.still, .moved(CGVector(dx: 5, dy: 0)), .resized])
    func backOnScreenWithinTheGraceLooksAgainOnce(_ change: AnchorChange) {
        var watch = OffscreenWatch()
        #expect(watch.observe(.offscreen, at: Self.ms(0)) == .waiting)
        #expect(watch.observe(change, at: Self.ms(200)) == .back)
        #expect(watch.observe(change, at: Self.ms(300)) == .none)
    }

    /// Off screen again after coming back: the grace starts over.
    @Test func theGraceStartsOverAfterComingBack() {
        var watch = OffscreenWatch()
        #expect(watch.observe(.offscreen, at: Self.ms(0)) == .waiting)
        #expect(watch.observe(.still, at: Self.ms(200)) == .back)
        #expect(watch.observe(.offscreen, at: Self.ms(300)) == .waiting)
        #expect(watch.observe(.offscreen, at: Self.ms(800)) == .waiting)
        #expect(watch.observe(.offscreen, at: Self.ms(900)) == .offscreen)
    }

    /// A window on screen says nothing, whatever it does.
    @Test(arguments: [AnchorChange.still, .moved(CGVector(dx: 0, dy: 3)), .resized])
    func aWindowOnScreenSaysNothing(_ change: AnchorChange) {
        var watch = OffscreenWatch()
        #expect(watch.observe(change, at: Self.ms(0)) == .none)
        #expect(watch.observe(change, at: Self.ms(5_000)) == .none)
    }

    /// `closed` ends the wait: a later poll starts afresh, on screen or off.
    @Test func afterClosedTheWatchStartsAfresh() {
        var watch = OffscreenWatch()
        #expect(watch.observe(.offscreen, at: Self.ms(0)) == .waiting)
        #expect(watch.observe(.gone, at: Self.ms(300)) == .closed)
        #expect(watch.observe(.still, at: Self.ms(400)) == .none)
        #expect(watch.observe(.offscreen, at: Self.ms(500)) == .waiting)
        #expect(watch.observe(.offscreen, at: Self.ms(1_000)) == .waiting)
    }

    /// `offscreen` ends the wait too: on screen afterwards is no `back`, and off screen again waits a whole grace.
    @Test func afterOffscreenTheWatchStartsAfresh() {
        var watch = OffscreenWatch()
        #expect(watch.observe(.offscreen, at: Self.ms(0)) == .waiting)
        #expect(watch.observe(.offscreen, at: Self.ms(600)) == .offscreen)
        #expect(watch.observe(.still, at: Self.ms(700)) == .none)
        #expect(watch.observe(.offscreen, at: Self.ms(800)) == .waiting)
        #expect(watch.observe(.offscreen, at: Self.ms(1_399)) == .waiting)
        #expect(watch.observe(.offscreen, at: Self.ms(1_400)) == .offscreen)
    }
}
