import Foundation

/// AppKit-backed (NSWorkspace). Requirements are async so a `@MainActor` implementation in HarkApp can conform
/// and be called from `PipelineController`.
public protocol Workspace: Sendable {
    func frontmostApplication() async -> AppIdentity?
    func activate(_ app: AppIdentity) async -> Bool
    /// Brings `app` forward and waits until it is the active one, or `timeout` passes. False when it did not come.
    func activateAndWait(_ app: AppIdentity, timeout: Duration) async -> Bool
    /// Launches the application at `url`, or brings it forward if it is running, and says whether it ended up in front.
    func openApplication(at url: URL) async -> ApplicationOpening
}

extension Workspace {
    /// For workspaces whose `activate` already answers once the app is in front.
    public func activateAndWait(_ app: AppIdentity, timeout: Duration) async -> Bool {
        await activate(app)
    }
}

/// What opening an application came to.
public enum ApplicationOpening: Sendable, Equatable {
    /// Running, and the app in front.
    case frontmost
    /// Running, but left behind the app that was in front: activation is the system's to grant, and an accessory app
    /// such as Hark asks from the background.
    case behind
    /// The system would not open it.
    case refused
    /// It opened and quit at once, and nothing else came forward: a launcher that failed to hand off, or an app that
    /// died at launch.
    case exited
}
