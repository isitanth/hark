import CoreGraphics
import Foundation
import HarkCore
import ScreenCaptureKit
import os

/// A framed region, captured and encoded in memory: what goes with the request, and the panel's thumbnail.
struct CapturedRegion: @unchecked Sendable {
    let encoded: EncodedRegion
    let thumbnail: CGImage?
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

    /// Off the main actor: the encode and the thumbnail take a few milliseconds of CPU.
    nonisolated static func capture(
        _ geometry: CaptureGeometry, display: CGDirectDisplayID, cap: Int
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
        let size = RegionImageEncoder.targetSize(
            width: Int(geometry.pixelSize.width), height: Int(geometry.pixelSize.height), cap: cap)
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
        logger.info(
            "captured \(encoded.pixelWidth, privacy: .public)×\(encoded.pixelHeight, privacy: .public) px, \(encoded.image.data.count, privacy: .public) bytes in \(ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000, privacy: .public) ms"
        )
        return .success(CapturedRegion(encoded: encoded, thumbnail: thumbnail(of: image)))
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
