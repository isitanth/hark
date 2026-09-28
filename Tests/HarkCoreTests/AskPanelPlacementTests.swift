import CoreGraphics
import HarkCore
import Testing

/// A 1512 x 982 display with a 33 pt menu bar and no Dock, and a 1920 x 1080 one to its right, its menu bar 25 pt.
private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 949)
private let external = CGRect(x: 1512, y: 0, width: 1920, height: 1055)
private let width: CGFloat = 520

private func place(_ remembered: CGPoint?, pointerOn screen: CGRect = builtIn) -> CGPoint {
    AskPanelPlacement.topLeft(
        panelWidth: width, remembered: remembered, visibleFrames: [builtIn, external], defaultFrame: screen)
}

@Suite struct AskPanelPlacementTests {
    @Test func byDefaultTheTopRightOfTheScreenUnderThePointer() {
        #expect(place(nil) == CGPoint(x: 1512 - 8 - 520, y: 949 - 8))
        #expect(place(nil, pointerOn: external) == CGPoint(x: 1512 + 1920 - 8 - 520, y: 1055 - 8))
    }

    @Test func whereTheUserLeftItIsKept() {
        #expect(place(CGPoint(x: 300, y: 600)) == CGPoint(x: 300, y: 600))
        #expect(place(CGPoint(x: 2000, y: 900), pointerOn: builtIn) == CGPoint(x: 2000, y: 900))
    }

    /// Dragged flush under the menu bar: the top edge on the frame's top line still counts as on the screen.
    @Test func aTopEdgeOnTheMenuBarLineIsOnTheScreen() {
        #expect(place(CGPoint(x: 400, y: 949)) == CGPoint(x: 400, y: 949))
    }

    @Test func aSpotPastTheRightEdgeIsPulledBackOnScreen() {
        #expect(place(CGPoint(x: 1400, y: 700)) == CGPoint(x: 1512 - 520, y: 700))
    }

    @Test func aSpotTooLowIsRaisedToLeaveRoom() {
        #expect(place(CGPoint(x: 300, y: 40)) == CGPoint(x: 300, y: AskPanelPlacement.minimumRoom))
    }

    /// The display it was left on is gone: back to the default spot.
    @Test func aSpotOnNoScreenFallsBackToTheDefault() {
        #expect(place(CGPoint(x: -900, y: 500)) == CGPoint(x: 1512 - 8 - 520, y: 949 - 8))
    }
}
