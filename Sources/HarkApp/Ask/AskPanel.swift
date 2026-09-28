import AppKit
import HarkCore
import SwiftUI

/// The Ask panel, the second of the app's two NSPanels (CLAUDE.md). Non-activating, so opening it from the Ask key
/// (M9) leaves the source app in front, and allowed to become key, for typing, Return and Esc. A Services call has
/// activated Hark already; every close brings the caller back (`AskPanelModel`).
///
/// It opens at the top right of the screen, or where the user last dragged it (`AskPanelPlacement`); it is dragged by
/// its background. Its height follows the SwiftUI content, growing downwards from wherever its top edge is.
final class AskPanel: NSPanel, NSWindowDelegate {
    static let width: CGFloat = 520

    /// The panel's new top-left corner, after the user moved it.
    var onUserMove: ((NSPoint) -> Void)?

    private let model: AskPanelModel
    /// Set while the panel places or resizes itself, so only the user's moves are reported.
    private var movingItself = false

    init(model: AskPanelModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        // On the Services path Hark is active and a click in the source app deactivates it: the popup stays.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = true
        delegate = self

        let host = NSHostingController(rootView: AskView(model: model))
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
        identifier = NSUserInterfaceItemIdentifier("ask-panel")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// At `remembered`, the top-left corner the user left it at, while that is on a screen; else at the top right of
    /// the screen under the pointer. Key without activating Hark.
    func open(at remembered: NSPoint?) {
        let screens = NSScreen.screens
        let pointer = NSEvent.mouseLocation
        let pointerScreen = screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let fallback = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let topLeft = AskPanelPlacement.topLeft(
            panelWidth: Self.width, remembered: remembered, visibleFrames: screens.map(\.visibleFrame),
            defaultFrame: pointerScreen?.visibleFrame ?? fallback)
        let screen = screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(topLeft) } ?? pointerScreen
        model.maxAnswerHeight = ((screen?.visibleFrame ?? fallback).height * 0.6).rounded()
        movingItself = true
        setFrameTopLeftPoint(topLeft)
        movingItself = false
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        orderOut(nil)
    }

    /// A change of height keeps the top edge where it is, and the panel on its screen: a long answer grows downwards
    /// to the screen's bottom, then the panel moves up. A move, the user's drag, changes no height and passes as is.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        let resizing = frame.height != self.frame.height
        if resizing {
            frame.origin.y = self.frame.maxY - frame.height
            if let visible = screen?.visibleFrame, frame.minY < visible.minY + 8 {
                frame.origin.y = visible.minY + 8
            }
        }
        let wasMovingItself = movingItself
        movingItself = wasMovingItself || resizing
        super.setFrame(frame, display: flag)
        movingItself = wasMovingItself
        invalidateShadow()
    }

    /// Posted synchronously by the move itself, so `movingItself` still says who moved it.
    func windowDidMove(_ notification: Notification) {
        guard !movingItself, isVisible else { return }
        onUserMove?(NSPoint(x: frame.minX, y: frame.maxY))
    }

    /// Esc is Cancel wherever the focus is: a text view would take it for completion.
    override func cancelOperation(_ sender: Any?) {
        model.cancel()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        {
            model.cancel()
            return
        }
        super.sendEvent(event)
    }
}

/// The panel's background: the popover material, blurred behind the window, since Hark is often not the active app.
/// A press on it drags the panel, which has no title bar to hold.
struct AskPanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = DraggableEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private final class DraggableEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
