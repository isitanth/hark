import AppKit
import HarkCore
import SwiftUI

/// The Ask panel, the second of the app's three AppKit windows (the project rules). Non-activating, so opening it from the Ask key
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
        // It shows while Hark is hidden too (Hide in its Dock icon's menu, ⌥⌘H elsewhere).
        canHide = false
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

    /// Key again without activating Hark, as at the open: a follow-up pressed from another app hears Return and Esc.
    func focus() {
        guard isVisible else { return }
        makeKey()
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

    /// Esc is Cancel wherever the focus is: a text view would take it for completion. Not the cancel sent by the Esc
    /// that commits a pending accent (M15.4).
    override func cancelOperation(_ sender: Any?) {
        guard AskComposition.cancels(markedText: holdsMarkedText, duringComposition: composingEscape) else { return }
        model.cancel()
    }

    /// The first responder holds marked text (M15): a dead key's ^. The press-and-hold bubble marks nothing.
    var holdsMarkedText: Bool {
        (firstResponder as? any NSTextInputClient)?.hasMarkedText() ?? false
    }

    /// Set while an Esc commits a pending accent in the field: the `cancelOperation:` it sends is the accent's.
    private var composingEscape = false

    /// Set while a Return commits a pending accent in the field: the field submits during that Return, before the
    /// committed text reaches the model (measured in M15.4), and that submit is the accent's.
    private(set) var composingReturn = false

    /// The listening panel's field has the keys: its field editor is the first responder. The review editor is no
    /// field editor.
    private var inListeningField: Bool {
        model.state == .listening && (firstResponder as? NSTextView)?.isFieldEditor == true
    }

    override func sendEvent(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, event.keyCode == 53 {
            escape(event, flags: flags)
            return
        }
        // Return while an accent is pending commits it in the field, before Done's default key ends the capture; the
        // field's submit during it neither sends nor is Done.
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76, holdsMarkedText,
            let responder = firstResponder
        {
            composingReturn = true
            responder.keyDown(with: event)
            composingReturn = false
            return
        }
        // ⌃⌥ held is the frame's (M11): its keys are never text in the listening field; Esc still drops the drag.
        if event.type == .keyDown, event.keyCode != 53, flags.contains([.control, .option]),
            firstResponder is NSTextView, model.state == .listening
        {
            return
        }
        super.sendEvent(event)
    }

    /// Esc: a follow-up waiting for its frame, a drag, then a pending accent's, then the ask's (M15.4).
    private func escape(_ event: NSEvent, flags: NSEvent.ModifierFlags) {
        // A follow-up waiting for its frame goes back to the previous answer (M12). Otherwise Esc while a frame is
        // being dragged drops that drag and keeps the ask, ⌃⌥ held or not, an accent pending or not.
        if model.cancelFollowUpAwaitingFrame() { return }
        if model.dropDrag?() == true { return }
        switch AskComposition.escape(markedText: holdsMarkedText, listeningField: inListeningField) {
        case .composition:
            // The field commits the accent, as TextEdit does, then sends cancelOperation:, which is the accent's.
            composingEscape = true
            super.sendEvent(event)
            composingEscape = false
        case .field where flags.isEmpty:
            // The listening field first: the accent bubble takes the Esc and closes; otherwise the field sends
            // cancelOperation:, which cancels the ask.
            super.sendEvent(event)
        case .panel where flags.isEmpty:
            model.cancel()
        case .field, .panel:
            super.sendEvent(event)
        }
    }
}
