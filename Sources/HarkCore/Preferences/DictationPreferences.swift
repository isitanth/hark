import Foundation

/// How a clipboard fallback is announced (M5).
public enum NotificationStyle: String, Sendable, CaseIterable {
    /// A notification with the system sound.
    case standard
    /// A notification without sound.
    case silent
    case off
}

/// The settings that are not commands.yaml's: how dictated text is delivered, which microphone, which words to bias
/// the decoder towards. Stored in the app's UserDefaults domain, one key each, so `defaults read` shows them plainly.
public struct DictationPreferences: Sendable, Equatable {
    public enum Key {
        public static let insertionMode = "HarkInsertionMode"
        public static let clipboardFallback = "HarkClipboardFallback"
        public static let notificationStyle = "HarkNotificationStyle"
        public static let inputDeviceUID = "HarkInputDeviceUID"
        public static let vocabulary = "HarkVocabulary"
        /// The live text in the HUD while recording, on a second Small model. Off unless set.
        public static let partialTranscript = "HarkPartialTranscript"
        /// The output volume lowered while Hark records. On unless set.
        public static let lowerOtherAudio = "HarkLowerOtherAudio"
    }

    /// Global default; the `apps:` table in commands.yaml overrides it per app. `clipboard` never types into an app.
    public var insertionMode: InsertionMode
    /// Off means text with nowhere to go is discarded as `clipboard_fallback_disabled` instead of copied.
    public var clipboardFallback: Bool
    public var notificationStyle: NotificationStyle
    /// `kAudioDevicePropertyDeviceUID` of the chosen input; nil follows the system default.
    public var inputDeviceUID: String?
    /// Already sanitized.
    public var vocabulary: [String]
    /// The live text in the HUD, on a second resident Small model. Off by default: it costs memory and energy.
    public var partialTranscript: Bool
    /// The output volume lowered to 0.3 × while Hark records, and put back after. On by default.
    public var lowerOtherAudio: Bool

    public init(
        insertionMode: InsertionMode = .accessibility, clipboardFallback: Bool = true,
        notificationStyle: NotificationStyle = .standard, inputDeviceUID: String? = nil, vocabulary: [String] = [],
        partialTranscript: Bool = false, lowerOtherAudio: Bool = true
    ) {
        self.insertionMode = insertionMode
        self.clipboardFallback = clipboardFallback
        self.notificationStyle = notificationStyle
        self.inputDeviceUID = inputDeviceUID
        self.vocabulary = Vocabulary.sanitized(vocabulary)
        self.partialTranscript = partialTranscript
        self.lowerOtherAudio = lowerOtherAudio
    }

    /// Unknown or mistyped values fall back to the default for that key alone.
    public init(defaults: UserDefaults) {
        self.init(
            insertionMode: defaults.string(forKey: Key.insertionMode).flatMap(InsertionMode.init(rawValue:))
                ?? .accessibility,
            clipboardFallback: defaults.object(forKey: Key.clipboardFallback) as? Bool ?? true,
            notificationStyle: defaults.string(forKey: Key.notificationStyle).flatMap(NotificationStyle.init(rawValue:))
                ?? .standard,
            inputDeviceUID: defaults.string(forKey: Key.inputDeviceUID).flatMap { $0.isEmpty ? nil : $0 },
            vocabulary: defaults.stringArray(forKey: Key.vocabulary) ?? [],
            partialTranscript: defaults.object(forKey: Key.partialTranscript) as? Bool ?? false,
            lowerOtherAudio: defaults.object(forKey: Key.lowerOtherAudio) as? Bool ?? true)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(insertionMode.rawValue, forKey: Key.insertionMode)
        defaults.set(clipboardFallback, forKey: Key.clipboardFallback)
        defaults.set(notificationStyle.rawValue, forKey: Key.notificationStyle)
        if let inputDeviceUID {
            defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID)
        } else {
            defaults.removeObject(forKey: Key.inputDeviceUID)
        }
        defaults.set(vocabulary, forKey: Key.vocabulary)
        defaults.set(partialTranscript, forKey: Key.partialTranscript)
        defaults.set(lowerOtherAudio, forKey: Key.lowerOtherAudio)
    }
}

/// The custom vocabulary: names and terms whisper should expect, fed to it as `initial_prompt`.
public enum Vocabulary {
    public static let maximumTerms = 100
    public static let maximumTermLength = 64

    /// Trimmed, inner whitespace collapsed, empties dropped, duplicates dropped ignoring case (first spelling wins),
    /// over-long terms dropped, capped at `maximumTerms`.
    public static func sanitized(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for term in terms {
            let cleaned = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !cleaned.isEmpty, cleaned.count <= maximumTermLength,
                seen.insert(cleaned.lowercased()).inserted
            else { continue }
            result.append(cleaned)
            if result.count == maximumTerms { break }
        }
        return result
    }

    /// How many of `terms`, in order, fit in the prompt budget. The rest are silently dropped by whisper's
    /// truncation otherwise, so the Model tab says so.
    public static func termsInPrompt(_ terms: [String]) -> Int {
        DecodeSpec.promptPhrases(from: terms).count
    }
}
