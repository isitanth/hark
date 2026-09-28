import CoreGraphics
import HarkCore
import Testing

/// A 1512 x 982 display with a 33 pt menu bar and no Dock: the visible frame is everything under the menu bar.
private let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
private let width: CGFloat = 520

@Suite struct AskPanelPlacementTests {
    @Test func insideTheTopRightOfTheCallersWindow() {
        let window = CGRect(x: 200, y: 150, width: 900, height: 700)
        let origin = AskPanelPlacement.topLeft(panelWidth: width, callerWindow: window, visibleFrame: visible)
        #expect(origin == CGPoint(x: 1100 - 12 - 520, y: 850 - 36))
    }

    /// A window narrower than the panel: the panel keeps its right edge on the window's and runs out to the left.
    @Test func aNarrowWindowStillAnchorsTheRightEdge() {
        let window = CGRect(x: 700, y: 300, width: 300, height: 400)
        let origin = AskPanelPlacement.topLeft(panelWidth: width, callerWindow: window, visibleFrame: visible)
        #expect(origin == CGPoint(x: 1000 - 12 - 520, y: 700 - 36))
    }

    @Test func aWindowPastTheScreenEdgeKeepsThePanelOnScreen() {
        let window = CGRect(x: 1200, y: 400, width: 800, height: 600)
        let origin = AskPanelPlacement.topLeft(panelWidth: width, callerWindow: window, visibleFrame: visible)
        #expect(origin == CGPoint(x: 1512 - 520 - 8, y: 949 - 8))
    }

    @Test func aWindowAtTheBottomLeavesRoomToListen() {
        let window = CGRect(x: 100, y: 0, width: 800, height: 120)
        let origin = AskPanelPlacement.topLeft(panelWidth: width, callerWindow: window, visibleFrame: visible)
        #expect(origin.y == AskPanelPlacement.minimumRoom)
    }

    @Test func noWindowMeansTheTopRightOfTheScreen() {
        let origin = AskPanelPlacement.topLeft(panelWidth: width, callerWindow: nil, visibleFrame: visible)
        #expect(origin == CGPoint(x: 1512 - 8 - 520, y: 949 - 8))
    }

    /// A second display above the primary one: CG's y grows downward from the primary's top, so it is negative there.
    @Test(arguments: [
        (CGRect(x: 100, y: 33, width: 800, height: 600), CGRect(x: 100, y: 349, width: 800, height: 600)),
        (CGRect(x: 0, y: -1000, width: 400, height: 300), CGRect(x: 0, y: 1682, width: 400, height: 300)),
    ])
    func windowListBoundsBecomeAppKitCoordinates(_ bounds: CGRect, _ expected: CGRect) {
        #expect(AskPanelPlacement.appKitRect(windowBounds: bounds, primaryHeight: 982) == expected)
    }
}
