import Foundation

/// `assistant:` in commands.yaml version 3: what sends a dictation to the assistant (M9.2).
///
/// ```yaml
/// assistant:
///   prefix: [hark, arc, hey hark, hey arc, hello hark, hello arc]   # matched exactly once normalized
/// ```
public struct AssistantConfig: Sendable, Equatable {
    /// As written. Whisper writes a French speaker's "Hark" as "Arc" (M9.0), and a fuzzy match would miss "arc" while
    /// catching "hard", "Marc" or "parc", so the spellings are listed rather than approximated.
    public var prefix: [String]

    public init(prefix: [String] = AssistantConfig.defaultPrefix) {
        self.prefix = prefix
    }

    /// "Hey Hark" as whisper writes it for the user ("Hey, Hark, how are you?", 2026-09-29), and "Hello". Each is
    /// exact too: "hey" alone is not a prefix.
    public static let defaultPrefix = ["hark", "arc", "hey hark", "hey arc", "hello hark", "hello arc"]
    public static let standard = AssistantConfig()
}
