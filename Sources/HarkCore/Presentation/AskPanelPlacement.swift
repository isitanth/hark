import CoreGraphics

/// Where the Ask panel opens: inside the top-right corner of the calling app's front window, below its title bar, or
/// the top right of the screen when that window is not known. AppKit coordinates: origin bottom left, y up.
public enum AskPanelPlacement {
    /// From the window's right edge, and down from its top past a title bar.
    public static let windowInset = CGSize(width: 12, height: 36)
    /// From the edges of the screen's visible frame.
    public static let screenMargin: CGFloat = 8
    /// The lowest the top edge may start above the bottom of the screen, room for the listening state.
    public static let minimumRoom: CGFloat = 200

    /// The panel's top-left corner.
    public static func topLeft(panelWidth: CGFloat, callerWindow: CGRect?, visibleFrame: CGRect) -> CGPoint {
        let anchor =
            callerWindow.map { CGPoint(x: $0.maxX - windowInset.width, y: $0.maxY - windowInset.height) }
            ?? CGPoint(x: visibleFrame.maxX - screenMargin, y: visibleFrame.maxY - screenMargin)
        let x = min(
            max(anchor.x - panelWidth, visibleFrame.minX + screenMargin),
            visibleFrame.maxX - panelWidth - screenMargin)
        let top = min(max(anchor.y, visibleFrame.minY + minimumRoom), visibleFrame.maxY - screenMargin)
        return CGPoint(x: x, y: top)
    }

    /// A `CGWindowListCopyWindowInfo` bounds rectangle (origin top left of the primary display, y down) in AppKit
    /// coordinates. `primaryHeight` is the height of the display with the menu bar, `NSScreen.screens[0]`.
    public static func appKitRect(windowBounds: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: windowBounds.minX, y: primaryHeight - windowBounds.maxY, width: windowBounds.width,
            height: windowBounds.height)
    }
}
