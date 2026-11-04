import Foundation

/// Where an ask's instruction comes from (M15): spoken, as every ask until 0.1.0, or typed into the listening panel's
/// field. Set to `.voice` at every press; the first committed character turns it `.typed` (`typingStarted`), and the
/// state stays `.capturing` so a frame can still be drawn.
public enum AskInput: Sendable, Equatable {
    case voice
    case typed
}
