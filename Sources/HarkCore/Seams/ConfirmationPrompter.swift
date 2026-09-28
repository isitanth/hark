import Foundation

/// AppKit-backed: asks the user before a `confirm: true` command runs. Async for the same reason as `Workspace`.
public protocol ConfirmationPrompter: Sendable {
    func confirm(_ command: ResolvedCommand) async -> Bool
    func dismiss() async
}

/// Stand-in until M6: declines, so the utterance logs `discarded(declined)`.
public struct NullConfirmationPrompter: ConfirmationPrompter {
    public init() {}

    public func confirm(_ command: ResolvedCommand) async -> Bool { false }
    public func dismiss() async {}
}
