import AppKit
import HarkCore
import SwiftUI
import os

/// The region overlay, the third of the app's AppKit windows (the project rules): one transparent panel per display,
/// built once and ordered out between uses. It is in front only while ⌃⌥ are held during an ask, and then it takes the
/// mouse, so neither a click nor a ⌃-click reaches the app beneath. It never becomes key or main, so the Ask panel
/// keeps the keyboard and its Esc.
final class RegionOverlayController {
    /// A drag began: the request waits for it.
    var onDragStarted: (() -> Void)?
    /// The drag ended on a frame: what to capture, on the display the drag began on.
    var onFramed: ((CaptureGeometry, CGDirectDisplayID) -> Void)?
    /// The drag framed nothing: a click, a frame under the minimum, or Esc while the mouse was down.
    var onAbandoned: (() -> Void)?

    private var panels: [RegionOverlayPanel] = []
    private var blocked = false
    private(set) var isShown = false
    /// The panel the mouse went down on, and where, in Cocoa global points, until the mouse comes up.
    private var drag: (panel: RegionOverlayPanel, start: CGPoint)?
    /// The overlays were disarmed during the drag: they go once it ends.
    private var hideAfterDrag = false
    /// The lens went, for any reason but `showLens` itself: the panel's button turns back to "Show Cells".
    var onLensDismissed: (() -> Void)?
    /// The panel showing the lens, and what takes the lens down while it shows.
    private var lensPanel: RegionOverlayPanel?
    private var lensHighlights: CellHighlights?
    private var lensMonitor: Any?
    private var lensObservers: [any NSObjectProtocol] = []
    /// The app in front when the lens showed: the caller, during review. Its own activation keeps the lens.
    private var lensCaller: pid_t?

    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "region")

    init() {
        rebuild()
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didChangeScreenParametersNotification)
            {
                self?.rebuild()
            }
        }
    }

    var isDragging: Bool { drag != nil }

    /// In front of every display, the dot at the pointer. `blocked`: framing cannot work, and the dot says so.
    func show(blocked: Bool) {
        // ⌃⌥ armed: framing takes priority over the lens.
        hideLens()
        self.blocked = blocked
        hideAfterDrag = false
        let pointer = NSEvent.mouseLocation
        for panel in panels {
            panel.state.blocked = blocked
            panel.state.pointer = panel.local(pointer)
            panel.orderFrontRegardless()
        }
        isShown = true
    }

    func setBlocked(_ blocked: Bool) {
        self.blocked = blocked
        for panel in panels { panel.state.blocked = blocked }
    }

    /// Out of the way, unless a drag is under way: that one ends at the mouse-up.
    func hide() {
        guard drag == nil else {
            hideAfterDrag = true
            return
        }
        for panel in panels {
            panel.orderOut(nil)
            panel.state.rect = nil
            panel.state.pointer = nil
        }
        isShown = false
    }

    /// `-HarkDebugPreview overlay`: the main display's overlay with a sample frame and the dot, for screenshots. It lets
    /// the mouse through, since a preview has no ask to end it; quitting the preview takes it down.
    func showPreview() {
        guard let panel = panels.first else { return }
        let size = panel.displayFrame.size
        let rect = CGRect(x: (size.width - 700) / 2, y: (size.height - 600) / 2, width: 700, height: 600).integral
        panel.ignoresMouseEvents = true
        panel.state.rect = rect
        panel.state.pointer = CGPoint(x: rect.maxX, y: rect.maxY)
        panel.orderFrontRegardless()
        isShown = true
    }

    // MARK: - The cells, as the Ask panel asks for them (M14 amendment)

    /// The frame's pixels the M13 lens copies, set through the panel from `AppModel`. M14.5 draws on the live window
    /// instead and removes it.
    var frameImage: ((UtteranceID) async -> CGImage?)?
    /// The cells showed (true) or went (false), for any reason: the panel's button reads "Hide Cells" or "Show Cells".
    var onCellsShownChanged: ((Bool) -> Void)?
    /// Why the cells cannot show, or not all of them, for the panel's one line; nil once they show in full. Not called
    /// by the M13 lens; M14.5's layer calls it.
    var onLayerNote: ((LayerNote?) -> Void)?
    private var cellsRequest: Task<Void, Never>?

    var cellsShown: Bool { isLensShown }

    /// Shows the cells over the screen. `current` is asked right before anything is drawn: false (the panel moved on)
    /// draws nothing.
    func showCells(_ highlights: CellHighlights, animated: Bool, current: @escaping @MainActor () -> Bool) {
        cellsRequest?.cancel()
        guard let frameImage else { return }
        cellsRequest = Task { [weak self] in
            guard let image = await frameImage(highlights.frameID), !Task.isCancelled, let self, current() else {
                return
            }
            self.showLens(highlights, image: image, animated: animated)
            self.onCellsShownChanged?(self.isLensShown)
        }
    }

    /// The cells go, and any request on its way with them.
    func hideCells() {
        cellsRequest?.cancel()
        cellsRequest = nil
        hideLens()
    }

    // MARK: - The lens (M13)

    var isLensShown: Bool { lensPanel != nil }

    /// Whether a display with this ID is connected: "Show Cells" is disabled when not.
    func hasDisplay(_ displayID: UInt32) -> Bool {
        panels.contains { $0.displayID == displayID }
    }

    /// The cells over their frame, on the frame's display only, under the Ask panel and click-through. Nothing while
    /// framing is armed.
    func showLens(_ highlights: CellHighlights, image: CGImage, animated: Bool) {
        guard !isShown, let panel = panels.first(where: { $0.displayID == highlights.displayID }) else { return }
        removeLens()
        panel.setLens(true)
        panel.state.lens = RegionLens(highlights: highlights, image: image, animated: animated)
        panel.orderFrontRegardless()
        lensPanel = panel
        lensHighlights = highlights
        lensCaller = NSWorkspace.shared.frontmostApplication?.processIdentifier
        lensMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] _ in
            self?.pointerActed(at: NSEvent.mouseLocation)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        lensObservers = [
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier
                MainActor.assumeIsolated { self?.activated(pid) }
            },
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideLens() }
            },
        ]
        Self.logger.info(
            "lens on display \(highlights.displayID, privacy: .public), \(highlights.cells.count, privacy: .public) cells"
        )
    }

    /// The lens goes and its image with it; the panel hears of it.
    func hideLens() {
        guard lensPanel != nil else { return }
        removeLens()
        onLensDismissed?()
        onCellsShownChanged?(false)
    }

    private func removeLens() {
        if let lensMonitor { NSEvent.removeMonitor(lensMonitor) }
        lensMonitor = nil
        for observer in lensObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        lensObservers = []
        if let panel = lensPanel {
            panel.state.lens = nil
            panel.orderOut(nil)
            panel.setLens(false)
        }
        lensPanel = nil
        lensHighlights = nil
        lensCaller = nil
    }

    /// A click or a scroll on the frame: what lies under it is about to change.
    private func pointerActed(at point: CGPoint) {
        guard let panel = lensPanel, let highlights = lensHighlights,
            highlights.contains(cocoaPoint: point, displayFrame: panel.displayFrame)
        else { return }
        hideLens()
    }

    /// Another app came forward: neither Hark nor the caller.
    private func activated(_ pid: pid_t?) {
        guard lensPanel != nil, pid != ProcessInfo.processInfo.processIdentifier, pid != lensCaller else { return }
        hideLens()
    }

    /// `-HarkDebugPreview overlay-lens`: c01's tints over a sample table on the main display, for screenshots.
    func showLensPreview() {
        guard let panel = panels.first else { return }
        let size = panel.displayFrame.size
        let frame = CGRect(x: (size.width - 700) / 2, y: (size.height - 600) / 2, width: 700, height: 600).integral
        guard let image = RegionLensSample.image(size: frame.size, scale: panel.scale) else { return }
        showLens(RegionLensSample.highlights(frame: frame, displayID: panel.displayID), image: image, animated: true)
    }

    /// Esc while the mouse is down: the drag frames nothing and the ask goes on. False when no drag is under way.
    func cancelDrag() -> Bool {
        guard let drag else { return false }
        drag.panel.state.rect = nil
        self.drag = nil
        onAbandoned?()
        if hideAfterDrag { hide() }
        return true
    }

    // MARK: - From the panels

    fileprivate func mouseDown(on panel: RegionOverlayPanel, at global: CGPoint) {
        guard drag == nil else { return }
        drag = (panel, global)
        panel.state.rect = CGRect(origin: panel.local(global), size: .zero)
        onDragStarted?()
    }

    fileprivate func mouseDragged(on panel: RegionOverlayPanel, to global: CGPoint) {
        guard let drag, drag.panel === panel else { return }
        let end = panel.clamped(global)
        let start = panel.local(drag.start)
        let current = panel.local(end)
        panel.state.rect = CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x),
            height: abs(current.y - start.y))
        panel.state.pointer = current
    }

    fileprivate func mouseUp(on panel: RegionOverlayPanel, at global: CGPoint) {
        guard let drag, drag.panel === panel else { return }
        self.drag = nil
        panel.state.rect = nil
        let geometry = captureGeometry(
            start: drag.start, end: panel.clamped(global), screen: panel.displayFrame, scale: panel.scale)
        if let geometry {
            Self.logger.info(
                "framed \(Int(geometry.pixelSize.width), privacy: .public)×\(Int(geometry.pixelSize.height), privacy: .public) px on display \(panel.displayID, privacy: .public)"
            )
            onFramed?(geometry, panel.displayID)
        } else {
            onAbandoned?()
        }
        if hideAfterDrag { hide() }
    }

    fileprivate func pointerMoved(on panel: RegionOverlayPanel, to global: CGPoint?) {
        panel.state.pointer = global.map(panel.local)
    }

    /// One panel per display, again: at launch and whenever a display comes, goes or changes.
    private func rebuild() {
        // A hide deferred to a drag's end is a hide: the overlays do not come back for a disarmed ask (M11 review R4).
        let wasShown = isShown && !hideAfterDrag
        if !wasShown {
            isShown = false
            hideAfterDrag = false
        }
        if let drag {
            drag.panel.state.rect = nil
            self.drag = nil
            onAbandoned?()
        }
        // The displays changed: the lens stays hidden until "Show Cells".
        hideLens()
        for panel in panels { panel.orderOut(nil) }
        panels = NSScreen.screens.map { RegionOverlayPanel(display: $0, owner: self) }
        if wasShown { show(blocked: blocked) }
    }
}

/// One display's overlay: borderless, non-activating, above the menu bar and full-screen apps, on every Space.
private final class RegionOverlayPanel: NSPanel {
    let displayID: CGDirectDisplayID
    /// The display's frame in Cocoa global points, and its backing scale.
    let displayFrame: CGRect
    let scale: CGFloat
    var state: RegionOverlayState {
        didSet {
            guard state != oldValue else { return }
            host.rootView = RegionOverlayView(state: state)
        }
    }
    private let host: NSHostingView<RegionOverlayView>

    init(display: NSScreen, owner: RegionOverlayController) {
        let number = display.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        displayID = number?.uint32Value ?? 0
        displayFrame = display.frame
        scale = display.backingScaleFactor
        state = RegionOverlayState(
            screenSize: display.frame.size, rect: nil, pointer: nil, blocked: false, scale: display.backingScaleFactor)
        host = NSHostingView(rootView: RegionOverlayView(state: state))
        super.init(
            contentRect: display.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        // With Hark hidden an overlay that hid with it would let the drag through to the app below.
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // A clear window would let clicks through its transparent pixels.
        ignoresMouseEvents = false
        let content = RegionOverlayContentView(frame: NSRect(origin: .zero, size: display.frame.size))
        content.owner = owner
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        contentView = content
        setFrame(display.frame, display: false)
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The lens's arrangement: under the Ask panel, on this Space only, click-through. Off, framing's exactly.
    func setLens(_ on: Bool) {
        if on {
            level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            ignoresMouseEvents = true
        } else {
            level = .screenSaver
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            ignoresMouseEvents = false
        }
    }

    /// A Cocoa global point in this overlay's own points, from its top-left corner, as the view draws.
    func local(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - displayFrame.minX, y: displayFrame.maxY - global.y)
    }

    /// A Cocoa global point kept on this display: a drag is clamped to the display it began on.
    func clamped(_ global: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(global.x, displayFrame.minX), displayFrame.maxX),
            y: min(max(global.y, displayFrame.minY), displayFrame.maxY))
    }
}

/// Takes every mouse event over the display itself, so the SwiftUI drawing above it never does, and so nothing
/// reaches the app beneath: no click, no ⌃-click menu, no right click.
private final class RegionOverlayContentView: NSView {
    weak var owner: RegionOverlayController?

    private var panel: RegionOverlayPanel? { window as? RegionOverlayPanel }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {}

    override func otherMouseDown(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // `activeAlways`: Hark is not the active app, and the dot must follow the pointer anyway.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel else { return }
        owner?.mouseDown(on: panel, at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel else { return }
        owner?.mouseDragged(on: panel, to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        guard let panel else { return }
        owner?.mouseUp(on: panel, at: NSEvent.mouseLocation)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let panel else { return }
        owner?.pointerMoved(on: panel, to: NSEvent.mouseLocation)
    }

    override func mouseEntered(with event: NSEvent) {
        guard let panel else { return }
        owner?.pointerMoved(on: panel, to: NSEvent.mouseLocation)
    }

    override func mouseExited(with event: NSEvent) {
        guard let panel else { return }
        owner?.pointerMoved(on: panel, to: nil)
    }
}
