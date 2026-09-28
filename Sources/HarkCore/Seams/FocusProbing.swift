import Foundation

/// Looks at where the user is when the trigger goes down. `AXFocusProbe` is the real one.
public protocol FocusProbing: Sendable {
    func probe() async -> FocusSnapshot
}

/// The frontmost app and nothing else. What the pipeline did before M4, and what tests use when the element does
/// not matter.
public struct WorkspaceFocusProbe: FocusProbing {
    public let workspace: any Workspace

    public init(workspace: any Workspace) {
        self.workspace = workspace
    }

    public func probe() async -> FocusSnapshot {
        FocusSnapshot(app: await workspace.frontmostApplication())
    }
}
