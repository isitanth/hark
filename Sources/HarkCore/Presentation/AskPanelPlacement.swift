import CoreGraphics

/// Where the Ask panel opens: where the user last left it, while that spot is still on a screen, and otherwise the top
/// right of the screen under the pointer. AppKit coordinates: origin bottom left, y up. The point is the panel's
/// top-left corner.
public enum AskPanelPlacement {
    /// From the edges of the screen's visible frame, for the default spot.
    public static let screenMargin: CGFloat = 8
    /// The lowest the top edge may start above the bottom of the screen, room for the listening state.
    public static let minimumRoom: CGFloat = 200

    /// - Parameters:
    ///   - remembered: the top-left corner the user dragged the panel to last, if any.
    ///   - visibleFrames: every screen's visible frame, the menu bar and the Dock left out.
    ///   - defaultFrame: the visible frame of the screen under the pointer.
    public static func topLeft(
        panelWidth: CGFloat, remembered: CGPoint?, visibleFrames: [CGRect], defaultFrame: CGRect
    ) -> CGPoint {
        // The top edge may sit on the frame's top line, which `contains` leaves out.
        if let remembered,
            let frame = visibleFrames.first(where: { $0.insetBy(dx: 0, dy: -1).contains(remembered) })
        {
            return CGPoint(
                x: min(remembered.x, frame.maxX - panelWidth),
                y: max(remembered.y, frame.minY + minimumRoom))
        }
        return CGPoint(
            x: defaultFrame.maxX - screenMargin - panelWidth, y: defaultFrame.maxY - screenMargin)
    }
}
