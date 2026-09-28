import Foundation

/// The decode language. Auto-detection costs one extra pass, so a fixed language is the faster choice.
public enum TranscriptionLanguage: String, Sendable, CaseIterable {
    case auto
    case english = "en"
    case french = "fr"

    /// Value for `whisper_full_params.language`. whisper.cpp spells auto-detection "auto".
    public var whisperCode: String { rawValue }
}
