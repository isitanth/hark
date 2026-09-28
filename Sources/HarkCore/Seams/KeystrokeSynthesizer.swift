import Foundation

/// CGEvent-backed. Async for the same reason as `Workspace`: the layout lookup behind it runs on the main actor.
public protocol KeystrokeSynthesizer: Sendable {
    /// Posts `chord` to whatever app has focus. False when it could not be posted, which without Accessibility trust
    /// is also what happens: the system drops the events without an error, so the implementation checks first.
    func post(_ chord: KeyChord) async -> Bool
}
