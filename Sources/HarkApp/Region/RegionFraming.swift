import CoreGraphics
import Foundation
import HarkCore
import os

/// Framing a region during an ask: the overlay comes while ⌃⌥ are held, a drag is captured at its mouse-up, the pixels
/// go to the controller's private slot, their summary through the pipeline, and a thumbnail to the panel. Armed only
/// while an ask's capture runs; a drag already under way when it ends still finishes, and the ask waits for it.
final class RegionFraming {
    /// The active profile's dialect, for the image's cap.
    var api = ProviderAPI.openAI

    private let controller: PipelineController
    private let panel: AskPanelModel
    /// The exact path's reader (M13), warmed when ⌃⌥ arms an exact ask's framing, never at launch.
    private let reader: any RegionReading
    private let overlay = RegionOverlayController()
    private let modifiers = ModifierMonitor()
    /// The ask whose capture is live, while it is.
    private var capturing: UtteranceID?
    /// The ask a drag began in, until its mouse-up: a drag outlives the capture that started it.
    private var dragging: UtteranceID?
    /// The ask in flight, whatever its phase: a drag whose ask has ended captures nothing.
    private var current: UtteranceID?
    /// The live turn of a conversation that holds as many frames as it may (M12): ⌃⌥ still arms, so the panel can say
    /// why, and a drag captures nothing.
    private var framesFull = false
    /// The ask in flight when it is exact: stamped at its press (M13), so a toggle mid-ask changes nothing, and a drag
    /// that ends after the capture still keeps its native raster.
    private var exact: UtteranceID?
    /// The controller's region calls, one after the other: two Tasks may reach an actor in either order, and a quick
    /// click must not see its `regionAbandoned` land before its `regionStarted` (M11 review R4).
    private var sending: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "region")

    init(controller: PipelineController, panel: AskPanelModel, reader: any RegionReading) {
        self.controller = controller
        self.panel = panel
        self.reader = reader
        modifiers.onChange = { [weak self] armed in self?.arm(armed) }
        overlay.onDragStarted = { [weak self] in self?.dragStarted() }
        overlay.onFramed = { [weak self] geometry, display in self?.framed(geometry, display: display) }
        overlay.onAbandoned = { [weak self] in self?.abandoned() }
        panel.dropDrag = { [weak self] in self?.overlay.cancelDrag() ?? false }
        // The panel shows and hides the cells through the overlay (M14 amendment); the layer reads a frame's anchor
        // from the latest snapshot and its reference from the controller's frame store, each freed with the frame.
        panel.lensOverlay = overlay
        overlay.layer.anchor = { [weak self] id in self?.anchors[id] }
        overlay.layer.reference = { [controller] id in await controller.raster(for: id)?.windowReference }
    }

    /// The anchors of the frames the ask in flight holds, by turn: the latest snapshot's, so a frame's anchor goes when
    /// the frame does.
    private var anchors: [UtteranceID: RegionAnchor] = [:]

    /// `-HarkDebugPreview overlay-layer`.
    func showLayerPreview() {
        overlay.layer.showPreview()
    }

    /// `-HarkDebugPreview overlay`.
    func showPreview() {
        overlay.showPreview()
    }

    func update(_ snapshot: PipelineSnapshot) {
        anchors = Self.anchors(in: snapshot.utterance)
        current = snapshot.phase != .idle && snapshot.utterance?.intent.isAsk == true ? snapshot.utterance?.id : nil
        let live = snapshot.phase == .capturing && snapshot.utterance?.intent.isAsk == true
        framesFull = live && snapshot.utterance?.acceptsFrame == false
        exact = snapshot.utterance?.math != nil ? current : nil
        let id = live ? snapshot.utterance?.id : nil
        guard id != capturing else { return }
        capturing = id
        if id != nil {
            modifiers.start()
        } else {
            modifiers.stop()
        }
    }

    private static func anchors(in context: UtteranceContext?) -> [UtteranceID: RegionAnchor] {
        guard let context else { return [:] }
        var anchors: [UtteranceID: RegionAnchor] = [:]
        for turn in context.thread?.turns ?? [] { anchors[turn.id] = turn.region?.anchor }
        if let parked = context.parked?.context { anchors[parked.id] = parked.region?.anchor }
        anchors[context.id] = context.region?.anchor
        return anchors
    }

    private func arm(_ armed: Bool) {
        panel.setFraming(armed)
        guard armed else {
            overlay.hide()
            return
        }
        if framesFull {
            panel.setFramingBlocked(.framesFull)
            overlay.show(blocked: true)
            Self.logger.info("framing armed, the conversation holds its frames")
            return
        }
        let denied = !ScreenRecordingPermission.isGranted
        if denied { panel.setFramingBlocked(.noScreenRecording) }
        overlay.show(blocked: denied || panel.visionVerdict == false)
        ScreenRegionCapturer.prefetch()
        guard !denied, panel.visionVerdict != false, capturing != nil, capturing == exact else {
            Self.logger.info("framing armed\(denied ? ", no Screen Recording" : "", privacy: .public)")
            return
        }
        let reader = reader
        Task.detached(priority: .utility) { await reader.prewarm() }
        Self.logger.info("framing armed, the reader warms")
    }

    private func dragStarted() {
        // At the frame cap the drag is dropped as it starts: no rectangle, no capture.
        if framesFull {
            _ = overlay.cancelDrag()
            return
        }
        guard let id = capturing else { return }
        dragging = id
        send { await $0.regionStarted(for: id) }
    }

    private func framed(_ geometry: CaptureGeometry, display: CGDirectDisplayID) {
        guard let id = dragging else { return }
        dragging = nil
        // The ask ended during the drag (cancelled, failed): nothing to capture for.
        guard id == current else { return }
        let cap = RegionImageEncoder.cap(for: api)
        let native = id == exact
        // The anchor (M14), synchronously at the mouse-up: the window list as it stands, before anything moves.
        let origin = LayerGeometry.displayOrigin(display)
        let zone = geometry.sourceRect.offsetBy(dx: origin.x, dy: origin.y)
        let anchor = RegionAnchor.choose(
            zone: zone, windows: WindowList.candidates(), harkPID: ProcessInfo.processInfo.processIdentifier)
        Task { [weak self, panel] in
            let result = await ScreenRegionCapturer.capture(
                geometry, display: display, cap: cap, native: native, anchor: anchor)
            switch result {
            case .success(let region):
                let summary = RegionSummary(
                    rect: geometry.sourceRect, pixelWidth: region.encoded.pixelWidth,
                    pixelHeight: region.encoded.pixelHeight, bytes: region.encoded.image.data.count,
                    displayID: display, anchor: region.anchor)
                panel.showRegion(thumbnail: region.thumbnail, for: id)
                let image = region.encoded.image
                // The raster and the window's reference live in this Task until the controller holds them: nothing
                // app-side keeps a reference.
                let raster = region.raster.map { RegionRaster(image: $0, windowReference: region.windowReference) }
                self?.send { await $0.attachRegion(image, summary: summary, for: id, raster: raster) }
            case .failure(let failure):
                if failure == .screenRecordingDenied { panel.setFramingBlocked(.noScreenRecording) }
                self?.send { await $0.regionFailed(failure, for: id) }
            }
        }
    }

    private func abandoned() {
        guard let id = dragging else { return }
        dragging = nil
        send { await $0.regionAbandoned(for: id) }
    }

    private func send(_ call: @escaping @Sendable (PipelineController) async -> Void) {
        let previous = sending
        sending = Task { [controller] in
            await previous?.value
            await call(controller)
        }
    }
}
