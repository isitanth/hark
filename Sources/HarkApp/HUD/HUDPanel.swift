import AppKit
import SwiftUI

/// The recording HUD, the first of the app's two NSPanels (the project rules). It must never become key or main: if it took
/// focus, the text field the user is dictating into would lose it. Every property below is there for that.
final class HUDPanel: NSPanel {
    static let size = NSSize(width: 280, height: 64)
    private static let fade: TimeInterval = 0.12

    /// Whether the panel is meant to be on screen; `isVisible` stays true through a fade-out.
    private(set) var isShowing = false
    /// Bumped by every show and hide, so a fade-out that ends after a new show does not order the panel out.
    private var generation = 0
    private var screenObserver: (any NSObjectProtocol)?
    private var focusGuard: HUDFocusGuard?

    init(model: HUDModel) {
        // Non-activating in the style mask, at init, where it takes effect: ordering it front does not activate Hark.
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        // Hark is never active, so a panel that hid on deactivation would never show.
        hidesOnDeactivate = false
        // A click on it cannot activate anything or eat a click meant for the app under it.
        ignoresMouseEvents = true
        // Moot beside `canBecomeKey`, kept as belt and braces.
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none

        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        // Active although the window is never key.
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 12
        material.layer?.masksToBounds = true
        let content = HUDHostingView(rootView: HUDContent(model: model))
        content.sizingOptions = []
        content.frame = material.bounds
        content.autoresizingMask = [.width, .height]
        material.addSubview(content)
        contentView = material

        setAccessibilityElement(false)
        setAccessibilityChildren([])
        focusGuard = HUDFocusGuard(watching: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows or hides on a change only: the origin is computed and the panel ordered front once per utterance.
    func setVisible(_ visible: Bool) {
        guard visible != isShowing else { return }
        isShowing = visible
        generation += 1
        if visible {
            show()
        } else {
            hide(generation)
        }
    }

    /// Bottom centre of the screen under the pointer, 120 pt above the Dock. A show during a fade-out fades back in
    /// from where the fade had got to.
    private func show() {
        if !isVisible {
            alphaValue = 0
            place(on: Self.screenUnderPointer())
            orderFrontRegardless()
            observeScreens()
        }
        fade(to: 1, completion: nil)
    }

    private func hide(_ hiding: Int) {
        fade(to: 0) { [weak self] in
            guard let self, self.generation == hiding else { return }
            self.orderOut(nil)
            self.stopObservingScreens()
        }
    }

    private func fade(to alpha: CGFloat, completion: (@MainActor () -> Void)?) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    private func place(on screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 120))
    }

    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }

    /// A latched or long-clip HUD can stay up for half an hour: a display added, removed or rearranged moves it to
    /// the new bottom centre, with `setFrameOrigin` only, no ordering and no key.
    private func observeScreens() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.place(on: self.screen ?? Self.screenUnderPointer())
            }
        }
    }

    private func stopObservingScreens() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }
}

/// The HUD's SwiftUI host: it never takes first responder, and with `sizingOptions` empty it never sizes the window.
private final class HUDHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { false }
}
