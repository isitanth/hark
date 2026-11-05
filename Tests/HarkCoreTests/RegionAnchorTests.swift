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
}
