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
        /// The detector hid the layer and waits for stillness.
        var waiting = false
        /// Bumped on every event that may move the page: a recapture started before it is let go unread.
        var generation = 0
        /// The band of the window the last search looked at, window-local points: a cell shows only inside it.
        var matchedBand: CGRect?
        /// The buttons pressed in the zone and still held, by number: the detector waits for the last release.
        var zonePresses: Set<Int> = []
        /// The buttons pressed elsewhere in the window and still held, by number, with the poll's move count at the
        /// press: the release hides the tints unless the window moved in between (a title-bar drag).
        var windowPresses: [Int: Int] = [:]
        /// Bumped by the poll on every move or resize of the window.
        var moves = 0
        /// Reads the window off screen over the polls: a closing window shows off screen a moment before it goes.
        var offscreenWatch = OffscreenWatch()
        /// Off screen for less than the watch's grace: hidden while it tells a close from a minimise.
        var offscreenWaiting = false
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

        var hidden: Bool { moving || needsRecapture || covered || pageMoving || recapturing || offscreenWaiting }
    }

    private let panel = RegionLayerPanel()
    private var session: Session?
    private var request: Task<Void, Never>?
    private var timer: Timer?
    private var monitor: Any?
    private var localMonitor: Any?
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
        // The note of an earlier show (another block's) never shows under this one.
        onNote?(nil)
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
    /// given; `announce` tells the panel the cells went, and says the note even when nil, so no earlier note stays
    /// under a block while nothing shows.
    private func end(note: LayerNote?, announce: Bool) {
        request?.cancel()
        request = nil
        session = nil
        timer?.invalidate()
        timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        panel.orderOut(nil)
        if announce || note != nil { onNote?(note) }
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
            // Off screen, or closing (M14.7): the poll's watch tells which. A close says so; minimised, its app hidden
            // or on another Space, the layer ends after the grace, and Show Cells tries again once it is back.
            waitOffscreen(session)
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
        let generation = session.generation
        request?.cancel()
        // The session is held weakly: once the layer ends, nothing here keeps its reference alive. The search's own
        // copy of the reference and the capture go with the detached search, which does not start once cancelled.
        request = Task { [weak self, weak session] in
            let capture = await ScreenRegionCapturer.recapture(windowID: anchor.windowID, band: band)
            guard let capture, !Task.isCancelled else {
                if !Task.isCancelled, let session {
                    self?.found(.notFound, capture: nil, for: session, generation: generation)
                }
                return
            }
            let job = Task.detached(priority: .userInitiated) { () -> ZoneMatch? in
                Task.isCancelled ? nil : search.run(capture)
            }
            let match = await withTaskCancellationHandler {
                await job.value
            } onCancel: {
                job.cancel()
            }
            guard let match, !Task.isCancelled, let session, self?.session === session else { return }
            self?.found(match, capture: capture, for: session, generation: generation)
        }
    }

    /// The search's answer, on the main actor: the zone's new place, the cells in view, or a note.
    private func found(_ match: ZoneMatch, capture: WindowBandCapture?, for session: Session, generation: Int) {
        guard self.session === session else { return }
        session.recapturing = false
        guard session.generation == generation else {
            // The page may have moved during the capture or the search: the answer is stale. The trigger kept pending
            // (the detector's, or a resize's) captures again once still.
            updateVisibility()
            return
        }
        if capture == nil {
            // The capture failed: the window may be closing or leaving the screen (M14.7). Gone says so; listed off
            // screen, the poll's watch tells which.
            let entry = WindowList.entry(session.anchor.windowID)
            guard let entry, entry.ownerPID == session.anchor.ownerPID else {
                end(note: .windowClosed, announce: true)
                return
            }
            if !entry.onScreen {
                waitOffscreen(session)
                return
            }
        }
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
        session.matchedBand = capture.band
        draw(session)
    }

    /// The cells whose whole box lies in the band the search matched, drawn at the zone's place now; the note says how
    /// many show. Those are the cells the search checked pixel by pixel: one under the title bar or the toolbar fails
    /// the check, and one cut by the band's edge is not drawn.
    private func draw(_ session: Session) {
        guard let matched = session.matchedBand else { return }
        let band = matched.insetBy(dx: -0.5, dy: -0.5)
        let cells = session.highlights.cells
        let visible = cells.filter { cell in
            band.contains(session.local(cell).offsetBy(dx: session.zoneOffset.x, dy: session.zoneOffset.y))
        }
        guard !visible.isEmpty else {
            end(note: .notFound, announce: true)
            return
        }
        let first = !session.drawn
        if first {
            guard session.current() else {
                // The panel moved on: nothing is drawn, and its button never reads Hide Cells over nothing.
                end(note: nil, announce: true)
                return
            }
            // A window over the zone keeps the layer hidden from the first draw, not from the poll's first tick.
            session.covered = WindowList.covers(session.zone, above: session.anchor.windowID, harkPID: harkPID)
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
        // A flick's momentum goes on over Hark's own windows (the Ask panel), which a global monitor never sees.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let record = Self.input(event).map {
                InputEvent(kind: $0.kind, at: $0.at, tail: $0.tail, local: true, button: $0.button)
            }
            MainActor.assumeIsolated { self?.input(record) }
            return event
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
                MainActor.assumeIsolated { self?.endForGood() }
            },
        ]
    }

    /// Another app came forward: neither Hark nor the window's owner.
    private func activated(_ pid: pid_t?) {
        guard let session, pid != harkPID, pid != session.anchor.ownerPID else { return }
        endForGood()
    }

    /// The layer ends for good (another app came forward, the Space changed). A framed window already gone says it
    /// closed: an app that quits with its last window brings another app forward as it closes it.
    private func endForGood() {
        guard let session else {
            hide()
            return
        }
        let entry = WindowList.entry(session.anchor.windowID)
        guard let entry, entry.ownerPID == session.anchor.ownerPID else {
            end(note: .windowClosed, announce: true)
            return
        }
        hide()
    }

    /// One tick: the window's bounds against the last poll, a cover over the zone, the page's stillness.
    private func poll() {
        guard let session else { return }
        let now = ContinuousClock.now
        let entry = WindowList.entry(session.anchor.windowID)
        let bounds = entry?.ownerPID == session.anchor.ownerPID ? entry?.bounds : nil
        let change = AnchorChange.classify(old: session.windowBounds, new: bounds, onScreen: entry?.onScreen ?? false)
        switch session.offscreenWatch.observe(change, at: now - session.started) {
        case .closed:
            end(note: .windowClosed, announce: true)
            return
        case .offscreen:
            // Minimised, hidden or on another Space: Show Cells once it is back. Before the first draw the panel says
            // why nothing showed.
            end(note: session.drawn ? nil : .notFound, announce: true)
            return
        case .waiting:
            // Off screen, or closing: a close keeps the window listed off screen for its animation (M14.7). Hidden
            // until the watch knows which, so a close says so. A recapture under way reads a window that is leaving:
            // its answer is let go unread.
            if !session.offscreenWaiting {
                session.offscreenWaiting = true
                session.generation += 1
            }
            updateVisibility()
            return
        case .back:
            comeBack(session, at: now)
        case .none:
            // Read off screen by a capture, not by the poll, and on screen again by now.
            if session.offscreenWaiting { comeBack(session, at: now) }
        }
        switch change {
        case .gone, .offscreen:
            // The watch has answered both.
            return
        case .moved:
            // A move does not move the page: the layer comes back at the new place once still, with no capture.
            session.windowBounds = bounds ?? session.windowBounds
            session.moves += 1
            session.moving = true
            session.stillSince = now
        case .resized:
            session.windowBounds = bounds ?? session.windowBounds
            session.moves += 1
            session.needsRecapture = true
            session.generation += 1
            session.stillSince = now
        case .still:
            break
        }
        // While a recapture runs, neither trigger is used up: each waits for it to end, and runs then.
        if !session.recapturing, let since = session.stillSince, now - since >= StillnessDetector.quiet {
            session.stillSince = nil
            guard session.sameScale(LayerGeometry.scale(of: session.windowBounds)) else {
                end(note: .otherScale, announce: true)
                return
            }
            session.moving = false
            if session.needsRecapture {
                session.needsRecapture = false
                recapture(session)
                return
            }
        }
        if !session.recapturing, session.detector.tick(at: now - session.started) == .recapture {
            session.waiting = false
            session.pageMoving = false
            recapture(session)
            return
        }
        session.covered = WindowList.covers(session.zone, above: session.anchor.windowID, harkPID: harkPID)
        updateVisibility()
    }

    /// On screen again after reading off screen: the page may have changed meanwhile, so the zone is looked for again
    /// once still.
    private func comeBack(_ session: Session, at now: ContinuousClock.Instant) {
        session.offscreenWaiting = false
        session.needsRecapture = true
        session.generation += 1
        session.stillSince = now
    }

    /// A capture read the window off screen (one about to start, or one that failed): hidden, and the poll's watch tells
    /// a close from a minimise (M14.7). Once it is back the zone is looked for again.
    private func waitOffscreen(_ session: Session) {
        session.recapturing = false
        session.offscreenWaiting = true
        session.needsRecapture = true
        updateVisibility()
    }

    /// An event as the layer reads it: its kind for the detector, where the pointer was, whether it is a scroll's tail
    /// (a momentum event or a finger's lift), and whether it reached one of Hark's own windows.
    private struct InputEvent {
        let kind: InputRecord.Kind
        let at: CGPoint
        var tail = false
        var local = false
        /// A button event's button number.
        var button = 0
    }

    /// What an event says to the stillness detector, read off the event at once. A scroll leaves momentum running only
    /// while a trackpad's momentum is under way (its momentum phase begun or changing); a wheel's notch, a finger's
    /// scroll and a momentum's last event leave none.
    nonisolated private static func input(_ event: NSEvent) -> InputEvent? {
        let point = NSEvent.mouseLocation
        switch event.type {
        case .scrollWheel:
            let momentum = event.momentumPhase
            let phase = event.phase
            // A finger resting on the trackpad, or lifted again without scrolling, moves nothing.
            if momentum.isEmpty, phase == .mayBegin { return nil }
            if momentum.isEmpty, phase.contains(.cancelled), event.scrollingDeltaX == 0, event.scrollingDeltaY == 0 {
                return nil
            }
            let ended = momentum.isEmpty || momentum.contains(.ended) || momentum.contains(.cancelled)
            let tail = !momentum.isEmpty || phase.contains(.ended) || phase.contains(.cancelled)
            return InputEvent(kind: .scroll(momentumEnded: ended), at: point, tail: tail)
        case .keyDown: return InputEvent(kind: .key, at: point)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return InputEvent(kind: .buttonDown, at: point, button: event.buttonNumber)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return InputEvent(kind: .buttonUp, at: point, button: event.buttonNumber)
        default: return nil
        }
    }

    /// A scroll over the window, a key while its app is in front, a button in the zone: the page may move. Once the
    /// detector waits, a scroll's tail counts wherever the pointer went, so a flick's momentum ends it. A button
    /// pressed elsewhere in the window counts at its release, unless the window moved meanwhile (plan §4.5).
    private func input(_ record: InputEvent?) {
        guard let session, let record else { return }
        let window = LayerGeometry.cocoa(session.windowBounds)
        var kind = record.kind
        let relevant: Bool
        switch record.kind {
        case .scroll:
            let tailWhileWaiting = session.waiting && record.tail
            relevant = record.local ? tailWhileWaiting : window.contains(record.at) || tailWhileWaiting
        case .key: relevant = NSWorkspace.shared.frontmostApplication?.processIdentifier == session.anchor.ownerPID
        case .buttonDown:
            if LayerGeometry.cocoa(session.zone).contains(record.at) {
                session.zonePresses.insert(record.button)
                relevant = true
            } else {
                if window.contains(record.at) { session.windowPresses[record.button] = session.moves }
                relevant = false
            }
        case .buttonUp:
            if session.zonePresses.remove(record.button) != nil {
                // The detector holds while any press in the zone is down: only the last release lets it go.
                relevant = session.zonePresses.isEmpty
            } else if let moves = session.windowPresses.removeValue(forKey: record.button) {
                // A click elsewhere in the window may change the page: hide now, recapture once still. A key, for
                // the detector, is an event with no held state, so a press still held in the zone keeps it waiting.
                relevant = moves == session.moves
                kind = .key
            } else {
                relevant = false
            }
        }
        guard relevant else { return }
        // A zone button's release moves nothing and arms no trigger: it leaves a recapture under way alone.
        if kind != .buttonUp { session.generation += 1 }
        let action = session.detector.record(InputRecord(kind: kind, at: ContinuousClock.now - session.started))
        if action == .hide {
            session.waiting = true
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
