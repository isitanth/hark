import CoreGraphics
import Foundation
import HarkCore
import ScreenCaptureKit
import os

/// A framed region, captured and encoded in memory: what goes with the request, and the panel's thumbnail. An exact
/// ask also keeps the native image itself, for the reader and the cell highlights (M13); nil otherwise.
struct CapturedRegion: @unchecked Sendable {
    let encoded: EncodedRegion
    let thumbnail: CGImage?
    let raster: CGImage?
    /// The window the zone lay on (M14), kept only when the capture's own window list shows it where the mouse-up saw
    /// it; nil otherwise, and then there is no layer.
    let anchor: RegionAnchor?
    /// The anchored window alone at the frame, over its search band, in grey: the layer's reference, for an exact ask
    /// with an anchor only.
    let windowReference: CGImage?
}

/// A fresh capture of the anchored window's band, in grey, and the band it covers in window-local points.
struct WindowBandCapture: @unchecked Sendable {
    let image: CGImage
    let band: CGRect
    let scale: CGFloat
}

/// The capture of a framed region, in memory only: ScreenCaptureKit takes the display-local rect with every Hark window
/// left out (the overlays, the Ask panel, the HUD), so what lies under the panel is captured as it is; ImageIO encodes
/// it. The pixels never touch disk.
enum ScreenRegionCapturer {
    nonisolated private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "region")
    /// The thumbnail's long edge, in pixels: the panel's chip is about 64 pt wide.
    nonisolated static let thumbnailEdge = 256

    /// Warms ScreenCaptureKit's list of displays and apps when framing arms, off the mouse-up's path (M11.0: 41-46 ms
    /// the first time in a process, 17 ms after).
    static func prefetch() {
        guard ScreenRecordingPermission.isGranted else { return }
        Task.detached {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                logger.info("prefetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Off the main actor: the encode and the thumbnail take a few milliseconds of CPU. `native`: an exact ask (M13)
    /// captures the display's own pixels, and the encoder caps the model's copy; otherwise ScreenCaptureKit captures
    /// at the cap, as before.
    nonisolated static func capture(
        _ geometry: CaptureGeometry, display: CGDirectDisplayID, cap: Int, native: Bool = false,
        anchor: RegionAnchor? = nil
    ) async -> Result<CapturedRegion, RegionFailure> {
        guard ScreenRecordingPermission.isGranted else { return .failure(.screenRecordingDenied) }
        let clock = ContinuousClock()
        let started = clock.now
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            logger.error("the shareable content failed: \(error.localizedDescription, privacy: .public)")
            return .failure(ScreenRecordingPermission.isGranted ? .captureFailed : .screenRecordingDenied)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let screen = content.displays.first(where: { $0.displayID == display }) else {
            logger.error("display \(display, privacy: .public) is not in the shareable content")
            return .failure(.captureFailed)
        }
        let hark = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: screen, excludingApplications: hark, exceptingWindows: [])
        let size = RegionImageEncoder.captureSize(
            width: Int(geometry.pixelSize.width), height: Int(geometry.pixelSize.height), cap: cap, native: native)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = geometry.sourceRect
        configuration.width = size.width
        configuration.height = size.height
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            logger.error("the capture failed: \(error.localizedDescription, privacy: .public)")
            return .failure(.captureFailed)
        }
        guard let encoded = RegionImageEncoder.encode(image, cap: cap) else {
            logger.error(
                "the encoder refused a \(image.width, privacy: .public)×\(image.height, privacy: .public) image")
            return .failure(.captureFailed)
        }
        let ms = (clock.now - started).components
        let raster = native ? ", raster \(image.width)×\(image.height) px" : ""
        logger.info(
            "captured \(encoded.pixelWidth, privacy: .public)×\(encoded.pixelHeight, privacy: .public) px, \(encoded.image.data.count, privacy: .public) bytes in \(ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000, privacy: .public) ms\(raster, privacy: .public)"
        )
        let held = anchor.flatMap { anchor in
            content.windows.first { $0.windowID == anchor.windowID }.flatMap { window in
                AnchorChange.classify(old: anchor.windowBounds, new: window.frame, onScreen: window.isOnScreen)
                    == .still ? (anchor, window) : nil
            }
        }
        if anchor != nil, held == nil { logger.info("the anchored window moved before the capture: no layer") }
        var reference: CGImage?
        if native, let (anchor, window) = held {
            let zone = CGRect(origin: anchor.offset, size: anchor.size)
            let band = LayerGeometry.band(zone: zone, windowSize: anchor.windowBounds.size)
            reference = await windowBand(window, band: band)?.image
        }
        return .success(
            CapturedRegion(
                encoded: encoded, thumbnail: thumbnail(of: image), raster: native ? image : nil, anchor: held?.0,
                windowReference: reference))
    }

    /// The anchored window again, over the band its zone lies in now (M14): the layer finds the zone in it. Nil when the
    /// window is gone from the shareable content or the capture fails.
    nonisolated static func recapture(windowID: UInt32, band: CGRect) async -> WindowBandCapture? {
        guard ScreenRecordingPermission.isGranted else { return nil }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            logger.error("the shareable content failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        return await windowBand(window, band: band)
    }

    /// The window alone (`desktopIndependentWindow`: no Hark window, nothing in front of it), opaque, without its
    /// shadow, its child windows included from macOS 14.2, over `band` in window-local points, at native resolution,
    /// turned grey at once.
    nonisolated private static func windowBand(_ window: SCWindow, band: CGRect) async -> WindowBandCapture? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let clipped = band.intersection(CGRect(origin: .zero, size: filter.contentRect.size))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = clipped
        configuration.width = Int((clipped.width * scale).rounded())
        configuration.height = Int((clipped.height * scale).rounded())
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.shouldBeOpaque = true
        configuration.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) { configuration.includeChildWindows = true }
        configuration.colorSpaceName = CGColorSpace.sRGB
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            logger.error("the window capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let grey = grey(image) else { return nil }
        return WindowBandCapture(image: grey, band: clipped, scale: scale)
    }

    /// 8-bit grey, drawn in memory: the colour copy goes with the caller's scope.
    nonisolated private static func grey(_ image: CGImage) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// A small copy for the panel's chip, in memory, drawn rather than encoded.
    nonisolated private static func thumbnail(of image: CGImage) -> CGImage? {
        let longEdge = max(image.width, image.height)
        let scale = min(1, Double(thumbnailEdge) / Double(max(longEdge, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
