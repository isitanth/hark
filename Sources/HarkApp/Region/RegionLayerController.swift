import AppKit
import HarkCore
import os

/// The anchored layer (M14, plan §4.5, decision 26): an exact answer's cells drawn over the live window the zone was
/// framed on, never over a copy of it. Before every show it captures that window's band and finds the zone again
/// against the reference taken at the frame; while it shows, a 10 Hz poll of the window hides it on a move, a resize, a
/// cover, and brings it back once still; a page that may move (a scroll, a key, a click in the zone) hides it until a
/// fresh capture finds the zone again with certainty. The captures live in memory as long as the search, never longer.
final class RegionLayerController {
    /// The anchor of a turn's frame, while the frame lives: read from the latest pipeline snapshot.
    var anchor: ((UtteranceID) -> RegionAnchor?)?
    /// The window's reference of a turn's frame, while the frame lives: the controller's frame store.
    var reference: ((UtteranceID) async -> CGImage?)?
    /// The cells showed (true) or went for good (false). A hide that comes back by itself (a move, a cover, a scroll)
    /// says nothing.
    var onShownChanged: ((Bool) -> Void)?
    /// Why the cells cannot show, or not all of them.
    var onNote: ((LayerNote?) -> Void)?

    /// What one show holds, until it ends: geometry, the reference, and why the layer is hidden for now.
    private final class Session {
        let highlights: CellHighlights
        let anchor: RegionAnchor
        let reference: CGImage
        /// The band the reference covers, window-local points, and its pixels per point.
        let referenceBand: CGRect
        let referenceScale: CGFloat
        let animated: Bool
        let current: @MainActor () -> Bool
        /// The window's bounds at the last poll, global points, top-left origin.
        var windowBounds: CGRect
        /// The zone's origin in the window, window-local points: the anchor's offset until the page moved.
        var zoneOffset: CGPoint
        /// Shown once: later shows are corrections and leave the panel's button alone.
        var drawn = false
        var moving = false
        var needsRecapture = false
        var covered = false
        var pageMoving = false
        var recapturing = false
        var stillSince: ContinuousClock.Instant?
        var detector = StillnessDetector()
        var buttonDown = false
        let started = ContinuousClock.now

        init(
            highlights: CellHighlights, anchor: RegionAnchor, reference: CGImage, animated: Bool,
            current: @escaping @MainActor () -> Bool
        ) {
            self.highlights = highlights
            self.anchor = anchor
            self.reference = reference
            referenceBand = LayerGeometry.band(
                zone: CGRect(origin: anchor.offset, size: anchor.size), windowSize: anchor.windowBounds.size)
            referenceScale = referenceBand.width > 0 ? CGFloat(reference.width) / referenceBand.width : 1
            self.animated = animated
            self.current = current
            windowBounds = anchor.windowBounds
            zoneOffset = anchor.offset
        }

        /// A cell's box in the zone's own points, from its top-left corner.
        func local(_ cell: HighlightedCell) -> CGRect {
            cell.box.offsetBy(dx: -highlights.frame.minX, dy: -highlights.frame.minY)
        }

        /// The zone now, global points, top-left origin.
        var zone: CGRect {
            CGRect(
                origin: CGPoint(x: windowBounds.minX + zoneOffset.x, y: windowBounds.minY + zoneOffset.y),
                size: highlights.frame.size)
        }

        /// The search compares pixels at the reference's scale: a display of another backing scale ends the layer.
        func sameScale(_ scale: CGFloat?) -> Bool {
            guard let scale else { return false }
            return abs(scale - referenceScale) < 0.05
        }

        var hidden: Bool { moving || needsRecapture || covered || pageMoving || recapturing }
    }

    private let panel = RegionLayerPanel()
    private var session: Session?
    private var request: Task<Void, Never>?
    private var timer: Timer?
    private var monitor: Any?
    private var observers: [any NSObjectProtocol] = []
    private let harkPID = ProcessInfo.processInfo.processIdentifier

    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "region")
    /// The poll's period (decision 26).
    static let pollInterval = 0.1

    var isShown: Bool { session?.drawn == true }

    // MARK: - Show and hide

    /// Finds the zone on the live window and draws the cells in view. `current` is asked right before drawing.
    func show(_ highlights: CellHighlights, animated: Bool, current: @escaping @MainActor () -> Bool) {
        end(note: nil, announce: false)
        guard let anchor = anchor?(highlights.frameID) else {
            Self.logger.info("no window under the frame: no layer")
            onNote?(.noWindow)
            onShownChanged?(false)
            return
        }
        let reference = reference
        request = Task { [weak self] in
            let image = await reference?(highlights.frameID)
            guard !Task.isCancelled, let self else { return }
            guard let image else {
                // The frame kept no reference: the window moved before the capture, or the frame is gone.
                self.onNote?(.noWindow)
                self.onShownChanged?(false)
                return
            }
            let session = Session(
                highlights: highlights, anchor: anchor, reference: image, animated: animated, current: current)
            self.session = session
            self.start(session)
            self.recapture(session)
        }
    }

    /// The cells go for good, and any search on its way with them.
    func hide() {
        end(note: nil, announce: true)
    }

    /// The layer ends: the panel goes, the poll and the monitors stop, the reference is let go. `note` is said when
    /// given; `announce` tells the panel the cells went.
    private func end(note: LayerNote?, announce: Bool) {
        request?.cancel()
        request = nil
        session = nil
        timer?.invalidate()
        timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        panel.orderOut(nil)
        if let note { onNote?(note) }
        // Said even when nothing was drawn, so the panel's button never reads Hide Cells over nothing.
        if announce { onShownChanged?(false) }
    }

    // MARK: - Finding the zone

    /// Captures the window's band around the zone, finds the zone in it, and draws or says why not. The capture is let
    /// go as soon as the answer is known.
    private func recapture(_ session: Session) {
        session.recapturing = true
        updateVisibility()
        let anchor = session.anchor
        guard let entry = WindowList.entry(anchor.windowID), entry.ownerPID == anchor.ownerPID else {
            end(note: .windowClosed, announce: true)
            return
        }
        guard entry.onScreen else {
            // Minimised, its app hidden or on another Space: Show Cells tries again once it is back.
            end(note: .notFound, announce: true)
            return
        }
        session.windowBounds = entry.bounds
        guard session.sameScale(LayerGeometry.scale(of: entry.bounds)) else {
            end(note: .otherScale, announce: true)
            return
        }
        let zoneInWindow = CGRect(origin: session.zoneOffset, size: session.highlights.frame.size)
        let band = LayerGeometry.band(zone: zoneInWindow, windowSize: entry.bounds.size)
        let search = Search(session: session)
        request?.cancel()
        request = Task { [weak self] in
            let capture = await ScreenRegionCapturer.recapture(windowID: anchor.windowID, band: band)
            guard let capture, !Task.isCancelled else {
                if !Task.isCancelled { self?.found(.notFound, capture: nil, for: session) }
                return
            }
            let match = await Task.detached(priority: .userInitiated) { search.run(capture) }.value
            guard !Task.isCancelled else { return }
            self?.found(match, capture: capture, for: session)
        }
    }

    /// The search's answer, on the main actor: the zone's new place, the cells in view, or a note.
    private func found(_ match: ZoneMatch, capture: WindowBandCapture?, for session: Session) {
        guard self.session === session else { return }
        session.recapturing = false
        guard case .found(let offset) = match, let capture else {
            Self.logger.info("the zone was not found again: \(String(describing: match), privacy: .public)")
            end(note: .notFound, announce: true)
            return
        }
        guard session.sameScale(capture.scale) else {
            end(note: .otherScale, announce: true)
            return
        }
        let search = Search(session: session)
        let origin = CGPoint(
            x: capture.band.minX + (search.zone.minX + offset.dx) / capture.scale,
            y: capture.band.minY + (search.zone.minY + offset.dy) / capture.scale)
        let previous = CGPoint(
            x: session.referenceBand.minX + search.zone.minX / session.referenceScale,
            y: session.referenceBand.minY + search.zone.minY / session.referenceScale)
        session.zoneOffset = CGPoint(
            x: session.anchor.offset.x + origin.x - previous.x, y: session.anchor.offset.y + origin.y - previous.y)
        draw(session)
    }

    /// The cells whose box lies in the window, drawn at the zone's place now; the note says how many show.
    private func draw(_ session: Session) {
        let window = CGRect(origin: .zero, size: session.windowBounds.size)
        let cells = session.highlights.cells
        let visible = cells.filter { cell in
            let box = session.local(cell).offsetBy(dx: session.zoneOffset.x, dy: session.zoneOffset.y)
            return window.contains(CGPoint(x: box.midX, y: box.midY))
        }
        guard !visible.isEmpty else {
            end(note: .notFound, announce: true)
            return
        }
        let first = !session.drawn
        if first {
            guard session.current() else {
                end(note: nil, announce: false)
                return
            }
        }
        let shifted = visible.map { cell in
            HighlightedCell(id: cell.id, box: session.local(cell), role: cell.role, uncertain: cell.uncertain)
        }
        panel.draw(cells: shifted, zoneSize: session.highlights.frame.size, animated: first && session.animated)
        panel.place(zone: LayerGeometry.cocoa(session.zone))
        session.drawn = true
        onNote?(visible.count < cells.count ? .outOfView(visible: visible.count, total: cells.count) : nil)
        updateVisibility()
        if first { onShownChanged?(true) }
    }

    private func updateVisibility() {
        guard let session, session.drawn, !session.hidden else {
            panel.orderOut(nil)
            return
        }
        panel.place(zone: LayerGeometry.cocoa(session.zone))
        panel.orderFrontRegardless()
    }

    // MARK: - Preview

    /// The stand-in window, while the preview shows.
    private var standIn: NSWindow?

    /// `-HarkDebugPreview overlay-layer`: the tints over a stand-in window, placed without a capture or a search.
    func showPreview() {
        let window = RegionLayerSample.standIn()
        standIn = window
        guard let content = window.contentView else { return }
        let zone = window.convertToScreen(content.convert(content.bounds, to: nil))
        panel.draw(cells: RegionLayerSample.cells, zoneSize: zone.size, animated: true)
        panel.place(zone: zone)
        panel.orderFrontRegardless()
    }

    // MARK: - While it shows

    /// The poll, the input monitor and today's hide rules, for this show only.
    private func start(_ session: Session) {
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [
                .scrollWheel, .keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
                .otherMouseUp,
            ]
        ) { [weak self] event in
            let record = Self.input(event)
            MainActor.assumeIsolated { self?.input(record) }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
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
                MainActor.assumeIsolated { self?.hide() }
            },
        ]
    }

    /// Another app came forward: neither Hark nor the window's owner.
    private func activated(_ pid: pid_t?) {
        guard let session, pid != harkPID, pid != session.anchor.ownerPID else { return }
        hide()
    }

    /// One tick: the window's bounds against the last poll, a cover over the zone, the page's stillness.
    private func poll() {
        guard let session, session.drawn || session.recapturing else { return }
        let now = ContinuousClock.now
        let entry = WindowList.entry(session.anchor.windowID)
        let bounds = entry?.ownerPID == session.anchor.ownerPID ? entry?.bounds : nil
        switch AnchorChange.classify(old: session.windowBounds, new: bounds, onScreen: entry?.onScreen ?? false) {
        case .gone:
            end(note: .windowClosed, announce: true)
            return
        case .offscreen:
            // Minimised, hidden or on another Space: Show Cells once it is back.
            end(note: nil, announce: true)
            return
        case .moved:
            // A move does not move the page: the layer comes back at the new place once still, with no capture.
            session.windowBounds = bounds ?? session.windowBounds
            session.moving = true
            session.stillSince = now
        case .resized:
            session.windowBounds = bounds ?? session.windowBounds
            session.needsRecapture = true
            session.stillSince = now
        case .still:
            break
        }
        if let since = session.stillSince, now - since >= StillnessDetector.quiet {
            session.stillSince = nil
            guard session.sameScale(LayerGeometry.scale(of: session.windowBounds)) else {
                end(note: .otherScale, announce: true)
                return
            }
            session.moving = false
            if session.needsRecapture, !session.recapturing {
                session.needsRecapture = false
                recapture(session)
                return
            }
        }
        if session.detector.tick(at: now - session.started) == .recapture, !session.recapturing {
            session.pageMoving = false
            recapture(session)
            return
        }
        session.covered = WindowList.covers(session.zone, above: session.anchor.windowID, harkPID: harkPID)
        updateVisibility()
    }

    /// What a global event says to the stillness detector, read off the event at once.
    nonisolated private static func input(_ event: NSEvent) -> (kind: InputRecord.Kind, at: CGPoint)? {
        let point = NSEvent.mouseLocation
        switch event.type {
        case .scrollWheel:
            let ended: Bool
            if !event.momentumPhase.isEmpty {
                ended = event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
            } else if !event.phase.isEmpty {
                ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            } else {
                // A wheel's notch: no momentum to come.
                ended = true
            }
            return (.scroll(momentumEnded: ended), point)
        case .keyDown: return (.key, point)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return (.buttonDown, point)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return (.buttonUp, point)
        default: return nil
        }
    }

    /// A scroll over the window, a key while its app is in front, a button in the zone: the page may move.
    private func input(_ record: (kind: InputRecord.Kind, at: CGPoint)?) {
        guard let session, let record else { return }
        let window = LayerGeometry.cocoa(session.windowBounds)
        let relevant: Bool
        switch record.kind {
        case .scroll: relevant = window.contains(record.at)
        case .key: relevant = NSWorkspace.shared.frontmostApplication?.processIdentifier == session.anchor.ownerPID
        case .buttonDown:
            relevant = LayerGeometry.cocoa(session.zone).contains(record.at)
            session.buttonDown = relevant
        case .buttonUp:
            relevant = session.buttonDown
            session.buttonDown = false
        }
        guard relevant else { return }
        let action = session.detector.record(InputRecord(kind: record.kind, at: ContinuousClock.now - session.started))
        if action == .hide {
            session.pageMoving = true
            updateVisibility()
        }
    }

    /// The search's inputs, off the main actor: the reference, and the zone and the cells in its pixels. Nothing here
    /// outlives the search.
    private struct Search: @unchecked Sendable {
        let reference: CGImage
        let zone: CGRect
        let cells: [CGRect]

        init(session: Session) {
            let anchor = session.anchor
            let scale = session.referenceScale
            let band = session.referenceBand
            func pixels(_ rect: CGRect) -> CGRect {
                CGRect(
                    x: (rect.minX - band.minX) * scale, y: (rect.minY - band.minY) * scale, width: rect.width * scale,
                    height: rect.height * scale
                ).integral
            }
            let window = CGRect(origin: .zero, size: anchor.windowBounds.size)
            reference = session.reference
            zone = pixels(CGRect(origin: anchor.offset, size: anchor.size).intersection(window))
            cells = session.highlights.cells.map { cell in
                pixels(session.local(cell).offsetBy(dx: anchor.offset.x, dy: anchor.offset.y))
            }
        }

        nonisolated func run(_ capture: WindowBandCapture) -> ZoneMatch {
            ZoneRegistration.find(reference: reference, recapture: capture.image, zone: zone, cells: cells)
        }
    }
}
