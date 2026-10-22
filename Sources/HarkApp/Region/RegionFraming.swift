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
    private let overlay = RegionOverlayController()
    private let modifiers = ModifierMonitor()
    /// The ask whose capture is live, while it is.
    private var capturing: UtteranceID?
    /// The ask a drag began in, until its mouse-up: a drag outlives the capture that started it.
    private var dragging: UtteranceID?
    /// The ask in flight, whatever its phase: a drag whose ask has ended captures nothing.
    private var current: UtteranceID?
    /// The controller's region calls, one after the other: two Tasks may reach an actor in either order, and a quick
    /// click must not see its `regionAbandoned` land before its `regionStarted` (M11 review R4).
    private var sending: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "region")

    init(controller: PipelineController, panel: AskPanelModel) {
        self.controller = controller
        self.panel = panel
        modifiers.onChange = { [weak self] armed in self?.arm(armed) }
        overlay.onDragStarted = { [weak self] in self?.dragStarted() }
        overlay.onFramed = { [weak self] geometry, display in self?.framed(geometry, display: display) }
        overlay.onAbandoned = { [weak self] in self?.abandoned() }
        panel.dropDrag = { [weak self] in self?.overlay.cancelDrag() ?? false }
    }

    /// `-HarkDebugPreview overlay`.
    func showPreview() {
        overlay.showPreview()
    }

    func update(_ snapshot: PipelineSnapshot) {
        current = snapshot.phase != .idle && snapshot.utterance?.intent.isAsk == true ? snapshot.utterance?.id : nil
        let live = snapshot.phase == .capturing && snapshot.utterance?.intent.isAsk == true
        let id = live ? snapshot.utterance?.id : nil
        guard id != capturing else { return }
        capturing = id
        if id != nil {
            modifiers.start()
        } else {
            modifiers.stop()
        }
    }

    private func arm(_ armed: Bool) {
        panel.setFraming(armed)
        guard armed else {
            overlay.hide()
            return
        }
        let denied = !ScreenRecordingPermission.isGranted
        if denied { panel.setFramingBlocked(.noScreenRecording) }
        overlay.show(blocked: denied || panel.visionVerdict == false)
        ScreenRegionCapturer.prefetch()
        Self.logger.info("framing armed\(denied ? ", no Screen Recording" : "", privacy: .public)")
    }

    private func dragStarted() {
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
        Task { [weak self, panel] in
            let result = await ScreenRegionCapturer.capture(geometry, display: display, cap: cap)
            switch result {
            case .success(let region):
                let summary = RegionSummary(
                    rect: geometry.sourceRect, pixelWidth: region.encoded.pixelWidth,
                    pixelHeight: region.encoded.pixelHeight, bytes: region.encoded.image.data.count,
                    displayID: display)
                panel.showRegion(thumbnail: region.thumbnail, for: id)
                let image = region.encoded.image
                self?.send { await $0.attachRegion(image, summary: summary, for: id) }
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
