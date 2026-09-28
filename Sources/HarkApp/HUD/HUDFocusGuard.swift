import AppKit
import os

/// A tripwire for the one thing the HUD must never do: take focus.
///
/// While the panel is on screen, fading included, Hark becoming active or the panel becoming key writes one
/// fault-level `hud.focus` line, which the unified log keeps (info lines it does not): the manual focus check greps
/// for it. Hark active with none of its own windows on screen is what the HUD taking focus would look like. An
/// activation while the panel, Settings or the welcome window is on screen is the user's doing and is logged at info
/// with that window's identifier. A click on one of Hark's notification banners also activates Hark and cannot be
/// told apart; the counted runs keep away from them.
final class HUDFocusGuard {
    private weak var panel: NSPanel?
    private var observers: [any NSObjectProtocol] = []
    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "hud")

    init(watching panel: NSPanel) {
        self.panel = panel
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.check("Hark became active") }
            })
        observers.append(
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.check("the HUD became key") }
            })
    }

    private func check(_ event: String) {
        guard let panel, panel.isVisible else { return }
        let key = NSApp.keyWindow
        let own = NSApp.windows.first { window in
            window !== panel && window.isVisible && !window.className.contains("StatusBar")
        }
        if let own, key !== panel {
            Self.logger.info(
                "hud.focus: \(event, privacy: .public) with \(Self.name(own), privacy: .public) on screen")
        } else {
            Self.logger.fault(
                "hud.focus: \(event, privacy: .public) while the HUD shows; key window \(key.map(Self.name) ?? "none", privacy: .public)"
            )
        }
    }

    private static func name(_ window: NSWindow) -> String {
        window.identifier?.rawValue ?? window.className
    }
}
