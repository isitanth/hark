import Foundation

/// Every `whisper_full_params` field Hark sets, derived from the clip and the language alone.
///
/// It is a value type so the decode configuration — above all `audioContext` — can be checked at its boundaries
/// with no model loaded and no GPU. `Transcriber` is the only thing that copies it into the C struct; the fields
/// it does not mention keep whisper's own defaults.
public struct DecodeSpec: Sendable, Equatable {
    /// whisper's encoder emits 1500 states for its fixed 30 s window: the mel front end produces 100 frames per
    /// second and the second conv layer strides them by 2, so 50 encoder states per second of audio.
    public static let encoderStatesPerSecond = 50
    /// The full window, and the value `whisper_model_n_audio_ctx` reports for every whisper model.
    public static let fullAudioContext = 1_500
    /// One second of slack. The conv receptive field and the mel tail reach past the last sample, and a clip that
    /// ends mid-word needs the decoder to see the run-out rather than a cliff.
    public static let audioContextHeadroom = encoderStatesPerSecond
    /// whisper.cpp pads the cross-attention K/V to 256 under flash attention, and its own examples use this grid
    /// (`-ac 768`). Aligning costs at most 255 states of encoder and keeps us off the unpadded path.
    public static let audioContextAlignment = 256
    /// Never ask for less than one aligned block. Truncating the encoder further moves its output far enough from
    /// what the decoder was trained on that greedy sampling starts repeating, which is worse than a slow decode.
    public static let minimumAudioContext = audioContextAlignment
    /// whisper.cpp's own default, `min(4, hardware_concurrency)`. Metal runs the encoder and the decoder; these
    /// threads only build the mel spectrogram, and more of them buys nothing.
    public static let maximumThreads = 4
    /// whisper uses at most `whisper_n_text_ctx()/2` prompt tokens (224) and prepends them to the decode, so a
    /// long vocabulary is silently truncated and pure latency. 800 characters is roughly 200 tokens.
    public static let promptCharacterBudget = 800

    /// `audio_ctx`: how much of the encoder window to compute. The single biggest latency lever here — a 3 s
    /// dictation clip pays for 512 of 1500 states instead of making the encoder chew 27 s of padding.
    public let audioContext: Int
    /// `n_threads`.
    public let threadCount: Int
    /// `language`. Auto-detection costs an extra pass, so a fixed language is the faster choice.
    public let language: TranscriptionLanguage
    /// `initial_prompt`: the command vocabulary, biasing the decoder towards the phrases that mean something
    /// here. It is a bias and not a constraint: whisper will still return anything it hears.
    public let initialPrompt: String?

    /// Fixed for every Hark decode. They are properties rather than literals inside the binding so that the tests
    /// hold the whole parameter set to account, and so one place answers "what did we ask whisper to do".
    public let translate = false
    /// One utterance, one decode. Past text would leak the previous command into this one.
    public let noContext = true
    public let noTimestamps = true
    /// Dictation is one segment. It also stops whisper splitting on a pause and returning the tail alone.
    public let singleSegment = true
    public let printSpecial = false
    public let printProgress = false
    public let printRealtime = false
    public let printTimestamps = false
    public let tokenTimestamps = false
    public let suppressBlank = true
    /// Non-speech tokens. Without it whisper spells out `[BLANK_AUDIO]`, `(music)` and friends.
    public let suppressNonSpeechTokens = true
    /// Greedy, one candidate: `strategy = WHISPER_SAMPLING_GREEDY`, `greedy.best_of = 1`.
    public let bestOf = 1
    public let temperature: Float = 0
    /// No temperature fallback. A retry pass doubles the worst case, and a fallback decode of a failed dictation
    /// clip is a hallucination waiting to happen; `HallucinationFilter` judges the first result instead.
    public let temperatureIncrement: Float = 0
    /// whisper's own default. `Transcriber` reads the reported probability back and applies its own thresholds.
    public let noSpeechThreshold: Float = 0.6

    public init(
        sampleCount: Int,
        sampleRate: Int = Int(SampleBuffer.sampleRate),
        language: TranscriptionLanguage,
        vocabulary: [String] = [],
        modelAudioContext: Int = fullAudioContext,
        usesCoreMLEncoder: Bool = false,
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.audioContext = Self.audioContext(
            forSampleCount: sampleCount, sampleRate: sampleRate, modelAudioContext: modelAudioContext,
            usesCoreMLEncoder: usesCoreMLEncoder)
        self.threadCount = min(Self.maximumThreads, max(1, processorCount))
        self.language = language
        self.initialPrompt = Self.prompt(from: vocabulary)
    }

    /// `ceil(seconds x 50)` states for the clip, plus a second of headroom, rounded up to the alignment and held
    /// between one block and what the loaded model can encode.
    ///
    /// **A Core ML encoder forces the full window.** The published `.mlmodelc` is compiled for one fixed input
    /// shape, the whole 1500-state window, and whisper.cpp hands it the mel buffer without reshaping. Ask for
    /// less and it does not fail: it returns an encoding the decoder cannot read, and the decode collapses to a
    /// single token. Measured 2026-09-21 on small q8_0 — `audio_ctx` 512 with Core ML decoded a 5.7 s sentence
    /// as "you", while the same clip at 1500 decoded correctly.
    public static func audioContext(
        forSampleCount sampleCount: Int,
        sampleRate: Int = Int(SampleBuffer.sampleRate),
        modelAudioContext: Int = fullAudioContext,
        usesCoreMLEncoder: Bool = false
    ) -> Int {
        // A context that reports nothing usable (an unloaded model) falls back to the full window, never to 1.
        let ceiling = modelAudioContext > 0 ? min(modelAudioContext, fullAudioContext) : fullAudioContext
        guard !usesCoreMLEncoder else { return ceiling }
        guard sampleRate > 0 else { return ceiling }
        let states = (max(0, sampleCount) * encoderStatesPerSecond + sampleRate - 1) / sampleRate
        let wanted = states + audioContextHeadroom
        let aligned = (wanted + audioContextAlignment - 1) / audioContextAlignment * audioContextAlignment
        return min(max(aligned, minimumAudioContext), ceiling)
    }

    /// Put in front of the terms so that every one of them follows a space, as a word does in the middle of a
    /// transcript. Measured on small (docs/acceptance/M3.md), 30 synthesized sentences in five voices, auto and fixed
    /// language, vocabulary "Hark", "Claude": no prompt spelled Hark right 28 times of 48; the bare list "Hark, Claude."
    /// 24, inventing "Harck"; with this label, 36. Every prompt shape cost "Claude", which the model already knew
    /// (36 of 42 without a prompt, about 25 with one), so the vocabulary is for words the model gets wrong. Prose
    /// prompts were rejected outright: under French they turned pure silence into a sentence the filter kept.
    public static let promptLabel = "Terms: "
    /// What the terms and their separators may use of `promptCharacterBudget` once the label is paid for.
    public static let promptPhraseBudget = promptCharacterBudget - promptLabel.count

    /// The vocabulary as one labelled, comma-separated list, truncated on a phrase boundary at the token budget.
    public static func prompt(from vocabulary: [String]) -> String? {
        let phrases = promptPhrases(from: vocabulary)
        guard !phrases.isEmpty else { return nil }
        return promptLabel + phrases.joined(separator: ", ") + "."
    }

    /// The phrases `prompt(from:)` keeps, in order: trimmed, deduplicated ignoring case, and cut at the first one
    /// that would overrun the budget.
    public static func promptPhrases(from vocabulary: [String]) -> [String] {
        var phrases: [String] = []
        var seen: Set<String> = []
        var length = 0
        for phrase in vocabulary {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            let cost = trimmed.count + (phrases.isEmpty ? 0 : 2)
            guard length + cost <= promptPhraseBudget else { break }
            phrases.append(trimmed)
            length += cost
        }
        return phrases
    }
}
