import Foundation

/// What a command does. One kind for now: commands open applications, and nothing else (your decision, 2026-09-23).
public enum ActionType: String, Sendable, CaseIterable {
    case openApp = "open_app"
}

public struct ResolvedCommand: Sendable, Equatable {
    /// The command's `id` in commands.yaml.
    public var id: String
    public var action: ActionType
    /// What the action acts on: for `open_app`, the application, by name or by path.
    public var target: String
    /// Ask before running. Nothing in commands.yaml sets it yet; the pipeline keeps its `confirming` path for the
    /// actions that will need it.
    public var confirm: Bool

    public init(id: String, action: ActionType, target: String, confirm: Bool = false) {
        self.id = id
        self.action = action
        self.target = target
        self.confirm = confirm
    }
}
