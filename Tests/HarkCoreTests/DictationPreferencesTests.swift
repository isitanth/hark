import Foundation
import Testing

@testable import HarkCore

/// A defaults suite of its own. An absolute suite name makes CFPreferences keep the domain at `<name>.plist` inside
/// the temporary directory rather than in ~/Library/Preferences, where every run would leave an empty plist behind
/// even after `removePersistentDomain`.
private final class ScratchDefaults {
    let directory: TemporaryDirectory
    let name: String
    let defaults: UserDefaults

    init() throws {
        directory = try TemporaryDirectory()
        name = directory.url.appendingPathComponent("preferences").path
        defaults = try #require(UserDefaults(suiteName: name))
    }

    /// A second handle on the same domain, as the next launch would open it.
    func reopened() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: name))
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

private typealias Key = DictationPreferences.Key

/// Every field away from its default, so a key that falls back is visible and the others must survive it.
private let customized = DictationPreferences(
    insertionMode: .paste, clipboardFallback: false, notificationStyle: .silent, inputDeviceUID: "USB-1",
    vocabulary: ["Hark"], partialTranscript: true, lowerOtherAudio: false)

struct MistypedValueCase: Sendable, CustomTestStringConvertible {
    let name: String
    /// Writes the bad value over the customized preferences.
    let write: @Sendable (UserDefaults) -> Void
    let expected: DictationPreferences

    var testDescription: String { name }
}

/// What UserDefaults hands back for a mistyped value was measured, not assumed: `string(forKey:)` renders a number
/// as its digits and a Bool as "1", `object(forKey:) as? Bool` takes 0 and 1 but not 2 or a string, and
/// `stringArray(forKey:)` refuses a lone string and an array with a non-string in it.
private let mistypedValueCases: [MistypedValueCase] = {
    func reset(_ change: (inout DictationPreferences) -> Void) -> DictationPreferences {
        var preferences = customized
        change(&preferences)
        return preferences
    }
    return [
        .init(
            name: "an unknown insertion mode", write: { $0.set("telepathy", forKey: Key.insertionMode) },
            expected: reset { $0.insertionMode = .accessibility }),
        .init(
            name: "an insertion mode in the wrong case", write: { $0.set("Paste", forKey: Key.insertionMode) },
            expected: reset { $0.insertionMode = .accessibility }),
        .init(
            name: "a number for the insertion mode", write: { $0.set(42, forKey: Key.insertionMode) },
            expected: reset { $0.insertionMode = .accessibility }),
        .init(
            name: "a string for the clipboard fallback", write: { $0.set("no", forKey: Key.clipboardFallback) },
            expected: reset { $0.clipboardFallback = true }),
        .init(
            name: "a 2 for the clipboard fallback", write: { $0.set(2, forKey: Key.clipboardFallback) },
            expected: reset { $0.clipboardFallback = true }),
        .init(
            name: "an unknown notification style", write: { $0.set("loud", forKey: Key.notificationStyle) },
            expected: reset { $0.notificationStyle = .standard }),
        .init(
            name: "a Bool for the notification style", write: { $0.set(true, forKey: Key.notificationStyle) },
            expected: reset { $0.notificationStyle = .standard }),
        .init(
            name: "an array for the device UID", write: { $0.set(["USB-1"], forKey: Key.inputDeviceUID) },
            expected: reset { $0.inputDeviceUID = nil }),
        .init(
            name: "a string for the live text", write: { $0.set("yes", forKey: Key.partialTranscript) },
            expected: reset { $0.partialTranscript = false }),
        .init(
            name: "a 2 for the live text", write: { $0.set(2, forKey: Key.partialTranscript) },
            expected: reset { $0.partialTranscript = false }),
        .init(
            name: "a string for lowering other audio", write: { $0.set("off", forKey: Key.lowerOtherAudio) },
            expected: reset { $0.lowerOtherAudio = true }),
        .init(
            name: "a date for lowering other audio", write: { $0.set(Date(), forKey: Key.lowerOtherAudio) },
            expected: reset { $0.lowerOtherAudio = true }),
        .init(
            name: "a lone string for the vocabulary", write: { $0.set("Hark", forKey: Key.vocabulary) },
            expected: reset { $0.vocabulary = [] }),
        .init(
            name: "a vocabulary with a number in it",
            write: { $0.set(["Hark", 1] as [Any], forKey: Key.vocabulary) },
            expected: reset { $0.vocabulary = [] }),
    ]
}()

@Suite struct DictationPreferencesTests {
    @Test func theDefaultsAreAccessibilityWithAClipboardFallbackAndTheSystemMicrophone() throws {
        let scratch = try ScratchDefaults()
        let expected = DictationPreferences(
            insertionMode: .accessibility, clipboardFallback: true, notificationStyle: .standard, inputDeviceUID: nil,
            vocabulary: [], partialTranscript: false, lowerOtherAudio: true)
        #expect(DictationPreferences() == expected)
        #expect(DictationPreferences(defaults: scratch.defaults) == expected)
    }

    /// The key names are what `defaults read` shows and what an existing install has stored; renaming one silently
    /// resets that setting.
    @Test func theKeysAreTheOnesAnInstallAlreadyHas() {
        #expect(Key.insertionMode == "HarkInsertionMode")
        #expect(Key.clipboardFallback == "HarkClipboardFallback")
        #expect(Key.notificationStyle == "HarkNotificationStyle")
        #expect(Key.inputDeviceUID == "HarkInputDeviceUID")
        #expect(Key.vocabulary == "HarkVocabulary")
        #expect(Key.partialTranscript == "HarkPartialTranscript")
        #expect(Key.lowerOtherAudio == "HarkLowerOtherAudio")
    }

    @Test(arguments: [
        DictationPreferences(),
        DictationPreferences(
            insertionMode: .paste, clipboardFallback: false, notificationStyle: .silent,
            inputDeviceUID: "BuiltInMicrophoneDevice", vocabulary: ["Kubernetes", "Hark", "Anthropic"]),
        DictationPreferences(
            insertionMode: .clipboard, notificationStyle: .off, inputDeviceUID: "AppleUSBAudioEngine:1"),
        DictationPreferences(clipboardFallback: false, vocabulary: ["ouvre le Finder", "Émile Zola"]),
        DictationPreferences(partialTranscript: true),
        DictationPreferences(lowerOtherAudio: false),
        DictationPreferences(partialTranscript: true, lowerOtherAudio: false),
    ])
    func aSaveLoadsBackEqual(_ preferences: DictationPreferences) throws {
        let scratch = try ScratchDefaults()
        preferences.save(to: scratch.defaults)
        #expect(DictationPreferences(defaults: try scratch.reopened()) == preferences)
    }

    /// Plain property-list types under each key, so `defaults read` and `defaults write` work on them by hand.
    @Test func theStoredValuesArePlain() throws {
        let scratch = try ScratchDefaults()
        DictationPreferences(
            insertionMode: .paste, clipboardFallback: false, notificationStyle: .off, inputDeviceUID: "USB-1",
            vocabulary: ["Hark"]
        ).save(to: scratch.defaults)

        let stored = try scratch.reopened()
        #expect(stored.object(forKey: Key.insertionMode) as? String == "paste")
        #expect(stored.object(forKey: Key.clipboardFallback) as? Bool == false)
        #expect(stored.object(forKey: Key.notificationStyle) as? String == "off")
        #expect(stored.object(forKey: Key.inputDeviceUID) as? String == "USB-1")
        #expect(stored.object(forKey: Key.vocabulary) as? [String] == ["Hark"])
    }

    @Test(arguments: mistypedValueCases)
    func aMistypedValueFallsBackForItsKeyAlone(_ mistyped: MistypedValueCase) throws {
        let scratch = try ScratchDefaults()
        customized.save(to: scratch.defaults)
        mistyped.write(scratch.defaults)
        #expect(DictationPreferences(defaults: try scratch.reopened()) == mistyped.expected)
    }

    /// Choosing the system default again removes the key rather than storing an empty UID.
    @Test func savingNoDeviceRemovesTheStoredOne() throws {
        let scratch = try ScratchDefaults()
        DictationPreferences(inputDeviceUID: "USB-1").save(to: scratch.defaults)
        DictationPreferences(inputDeviceUID: nil).save(to: scratch.defaults)

        let stored = try scratch.reopened()
        #expect(stored.object(forKey: Key.inputDeviceUID) == nil)
        #expect(DictationPreferences(defaults: stored).inputDeviceUID == nil)
    }

    @Test func anEmptyDeviceUIDFollowsTheSystemDefault() throws {
        let scratch = try ScratchDefaults()
        scratch.defaults.set("", forKey: Key.inputDeviceUID)
        #expect(DictationPreferences(defaults: scratch.defaults).inputDeviceUID == nil)
    }

    @Test func theVocabularyIsSanitizedOnLoad() throws {
        let scratch = try ScratchDefaults()
        scratch.defaults.set(
            ["  Hark ", "hark", "", "Kubernetes \t cluster", String(repeating: "x", count: 65), "HARK"],
            forKey: Key.vocabulary)
        #expect(DictationPreferences(defaults: scratch.defaults).vocabulary == ["Hark", "Kubernetes cluster"])
    }

    @Test func theVocabularyIsSanitizedOnInit() {
        #expect(DictationPreferences(vocabulary: [" Zola ", "zola", "  "]).vocabulary == ["Zola"])
    }
}
