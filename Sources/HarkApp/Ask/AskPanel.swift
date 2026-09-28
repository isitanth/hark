import AppKit
import HarkCore
import SwiftUI

/// The Ask panel, the second of the app's two NSPanels (CLAUDE.md). Non-activating, so opening it from the Ask key
/// (M9) leaves the source app in front, and allowed to become key, for typing, Return and Esc. A Services call has
/// activated Hark already; every close brings the caller back (`AskPanelModel`).
///
/// It opens inside the top-right corner of the caller's front window (`AskPanelPlacement`) and can be dragged by its
/// background. Its height follows the SwiftUI content, growing downwards from wherever its top edge is.
final class AskPanel: NSPanel {
    static let width: CGFloat = 520

    private let model: AskPanelModel

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

        let host = NSHostingController(rootView: AskView(model: model))
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
        identifier = NSUserInterfaceItemIdentifier("ask-panel")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Over `caller`'s front window, or at the top right of the screen under the pointer, and key without activating
    /// Hark.
    func open(over caller: AppIdentity?) {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.maxY ?? 0
        let window = caller.flatMap { Self.frontWindowBounds(of: $0.processID) }.map {
            AskPanelPlacement.appKitRect(windowBounds: $0, primaryHeight: primaryHeight)
        }
        let pointer = NSEvent.mouseLocation
        let screen =
            window.flatMap { window in
                screens.first { $0.frame.contains(NSPoint(x: window.maxX - 1, y: window.maxY - 1)) }
                    ?? screens.max { $0.frame.intersection(window).area < $1.frame.intersection(window).area }
            }
            ?? screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        model.maxAnswerHeight = (visible.height * 0.6).rounded()
        setFrameTopLeftPoint(
            AskPanelPlacement.topLeft(panelWidth: Self.width, callerWindow: window, visibleFrame: visible))
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        orderOut(nil)
    }

    /// A change of height keeps the top edge where it is, and the panel on its screen: a long answer grows downwards
    /// to the screen's bottom, then the panel moves up. A move, the user's drag, changes no height and passes as is.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if frame.height != self.frame.height {
            frame.origin.y = self.frame.maxY - frame.height
            if let visible = screen?.visibleFrame, frame.minY < visible.minY + 8 {
                frame.origin.y = visible.minY + 8
            }
        }
        super.setFrame(frame, display: flag)
        invalidateShadow()
    }

    /// The bounds of `pid`'s frontmost ordinary window on screen, as the window server lists them front to back. Needs
    /// no permission: only window names are private.
    private static func frontWindowBounds(of pid: Int32) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 100, rect.height > 100
            else { continue }
            return rect
        }
        return nil
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

extension CGRect {
    fileprivate var area: CGFloat { isNull ? 0 : width * height }
}
