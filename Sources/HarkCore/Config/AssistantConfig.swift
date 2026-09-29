import Foundation

/// `assistant:` in commands.yaml version 3: what sends a dictation to the assistant (M9.2).
///
/// ```yaml
/// assistant:
///   prefix: [hark, arc, ark]         # the name, as whisper writes it; matched exactly once normalized
///   greetings: [hey, hello, salut]   # may come before the name: "Hey Hark, …", "Salut Arc, …"
/// ```
public struct AssistantConfig: Sendable, Equatable {
    /// As written. Whisper writes a French speaker's "Hark" as "Arc" (M9.0) and at times "Ark" (the user's test of
    /// 2026-09-29); a fuzzy match would miss "arc" while catching "hard", "Marc" or "parc", so the spellings are listed
    /// rather than approximated.
    public var prefix: [String]
    /// Words that may come before a prefix, never alone: "Hey" by itself is dictation.
    public var greetings: [String]

    public init(
        prefix: [String] = AssistantConfig.defaultPrefix, greetings: [String] = AssistantConfig.defaultGreetings
    ) {
        self.prefix = prefix
        self.greetings = greetings
    }

    public static let defaultPrefix = ["hark", "arc", "ark"]
    /// "Hey, Hark, how are you?", "Hey Ark, …", "Salut Arc ! …": the user's own openings on 2026-09-29.
    public static let defaultGreetings = ["hey", "hello", "salut"]
    public static let standard = AssistantConfig()
}
