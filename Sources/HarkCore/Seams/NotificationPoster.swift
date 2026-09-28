import Foundation

/// UserNotifications-backed. Async for the same reason as `Workspace`. Asks for permission on first use.
public protocol NotificationPoster: Sendable {
    func post(_ content: NotificationContent) async -> NotificationDelivery
    /// Whether the user has refused, as the system reports it now. Nil when nothing has been asked yet, or there
    /// is no bundle to ask from. Never prompts, so it is safe to call whenever the panel appears.
    func isDenied() async -> Bool?
}

/// Posts nothing. For tests, and for a process that has no bundle to post from.
public struct NullNotificationPoster: NotificationPoster {
    public init() {}

    public func post(_ content: NotificationContent) async -> NotificationDelivery { .failed }

    public func isDenied() async -> Bool? { nil }
}
