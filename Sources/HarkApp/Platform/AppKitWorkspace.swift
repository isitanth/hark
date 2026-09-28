import AppKit
import HarkCore
import os

/// Main-actor isolated (HarkApp's default). Satisfies HarkCore's async `Workspace` seam, so
/// `PipelineController` awaits it and the call hops to the main actor.
final class AppKitWorkspace: Workspace {
    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "actions")

    func frontmostApplication() async -> AppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppIdentity(app)
    }

    func activate(_ app: AppIdentity) async -> Bool {
        NSRunningApplication(processIdentifier: app.processID)?.activate() ?? false
    }

    /// Opens the app and waits to see it in front. Hark asks from the background — its HUD never takes focus — and
    /// under macOS 14's cooperative activation the system may launch or unhide the app and leave it behind; that is
    /// reported rather than taken for success, after one more direct request.
    ///
    /// What "in front" can mean depends on the app. A menu-bar or background-only app is never the active one, so
    /// launched is all it can be. A cold launch of a large app takes seconds, and LaunchServices brings it forward once
    /// it has finished launching, so the window for that starts then; one still launching after eight seconds counts as
    /// opened and is left to come forward on its own, the one success not seen in front. A launcher that hands off to
    /// another process and quits has done what was asked when another app came forward.
    ///
    /// A process that dies before it checks in with LaunchServices comes back terminated, its activation policy
    /// unknown (-1): it is tested for first, and only a live accessory or background-only app skips the wait.
    func openApplication(at url: URL) async -> ApplicationOpening {
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            Self.logger.error(
                "\(url.path(), privacy: .public) did not open: \(error.localizedDescription, privacy: .public)")
            return .refused
        }
        let path = ApplicationLocator.path(of: url)
        if app.isTerminated { return await Self.afterExit(app, from: before, path) }
        if app.activationPolicy == .accessory || app.activationPolicy == .prohibited { return .frontmost }
        guard await Self.finishesLaunching(app, within: .seconds(8)) else {
            if app.isTerminated { return await Self.afterExit(app, from: before, path) }
            Self.logger.info("\(path, privacy: .public) is still launching; it comes forward on its own")
            return .frontmost
        }
        if await Self.becomesActive(app, within: .seconds(2)) { return .frontmost }
        _ = app.activate()
        if await Self.becomesActive(app, within: .seconds(1)) { return .frontmost }
        if app.isTerminated { return await Self.afterExit(app, from: before, path) }
        return .behind
    }

    /// Gone without coming forward. A launcher hands off to the app it starts, which can take a moment to come
    /// forward, so another regular app in front within two seconds counts as what was asked for; nothing new in front
    /// means the app quit on its own. A click on another app in those two seconds reads as a hand-off: the system says
    /// nothing that tells them apart.
    private static func afterExit(
        _ app: NSRunningApplication, from before: pid_t?, _ path: String
    ) async -> ApplicationOpening {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !handedOff(from: before, launched: app.processIdentifier) {
            guard clock.now < deadline else {
                Self.logger.info("\(path, privacy: .public) quit at once and nothing came forward")
                return .exited
            }
            try? await clock.sleep(for: .milliseconds(50))
        }
        Self.logger.info("\(path, privacy: .public) quit at once and handed off")
        return .frontmost
    }

    /// Another app in front that a launcher could have handed off to: alive, regular, neither the one in front before
    /// nor the one that quit. The alert a crash raises (UserNotificationCenter, an accessory app) and a moment with
    /// nothing in front do not count.
    private static func handedOff(from before: pid_t?, launched: pid_t) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.processIdentifier != before && front.processIdentifier != launched && !front.isTerminated
            && front.activationPolicy == .regular
    }

    private static func finishesLaunching(_ app: NSRunningApplication, within timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !app.isFinishedLaunching {
            if app.isTerminated || clock.now >= deadline { return false }
            try? await clock.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Brings `app` forward and waits until the system says it is the active one, because `activate` only asks.
    /// False when it is gone, refuses, or takes longer than `timeout`.
    ///
    /// `isActive` is read rather than `didActivateApplication` awaited: the notification sequence subscribes only
    /// once something iterates it, so an app that comes forward immediately — the usual case, since Hark is an
    /// accessory app and closing its panel hands activation straight back — would raise it before anything was
    /// listening, and the wait would run to the deadline for an activation that had already happened.
    func activateAndWait(_ app: AppIdentity, timeout: Duration) async -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.processID), !running.isTerminated else {
            return false
        }
        if running.isActive { return true }
        guard running.activate() else { return false }
        return await Self.becomesActive(running, within: timeout)
    }

    private static func becomesActive(_ app: NSRunningApplication, within timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !app.isActive {
            if app.isTerminated || clock.now >= deadline { return false }
            // Yields the main actor, so the run loop can deliver the activation this is waiting for.
            try? await clock.sleep(for: .milliseconds(20))
        }
        return true
    }
}

extension AppIdentity {
    /// Whether the bundle carries a Chromium framework is read from disk, so it is answered once per look at an app.
    nonisolated init(_ app: NSRunningApplication) {
        let chromium = app.bundleURL.map {
            AppIdentity.embedsChromium(bundleURL: $0, exists: FileManager.default.fileExists)
        }
        self.init(
            bundleID: app.bundleIdentifier, name: app.localizedName, processID: app.processIdentifier,
            embedsChromium: chromium ?? false)
    }
}
