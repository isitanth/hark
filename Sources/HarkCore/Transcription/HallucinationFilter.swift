import Foundation

/// Decides whether a decode is speech or one of whisper's inventions.
///
/// Whisper was trained on subtitled video, and on silence it reaches for that training set: "Thank you.",
/// "Sous-titrage Société Radio-Canada", "[BLANK_AUDIO]", "(music)", or one token repeated until the context runs
/// out. A dictation app must not turn those into a command or paste them into a document, so a rejected decode
/// becomes a blank `Transcript` and the pipeline logs `discarded / empty_transcript`.
///
/// An unmistakable training-set artefact is rejected on sight. A single word that is also plausible speech
/// ("oui", "okay") needs corroboration, and the evidence for that is the audio's own level — not whisper's
/// `no_speech_prob`.
///
/// That distinction was bought with a real decode. Given two seconds of digital silence, whisper small returns
/// "you" with `no_speech_prob` of 0.00000032: it is not merely unsure, it is confidently wrong. Anything
/// conditioned on whisper doubting itself therefore never fires when it is needed, so the weak-filler rule
/// leans on `audioLevel` instead and keeps `no_speech_prob` only as a second, rarely-useful opinion.
public struct HallucinationFilter: Sendable {
    public struct Thresholds: Sendable, Equatable {
        /// `no_speech_prob` above which a weak artefact is treated as silence. whisper's own default.
        public var noSpeech: Double
        /// `no_speech_prob` above which the text does not matter. Digital silence scores far above this.
        public var certainNoSpeech: Double
        /// How many repeats of the same token, or of the same short run of tokens, count as a loop.
        public var repeats: Int
        /// Mean RMS below which the clip is too quiet to have carried the word whisper claims to have heard.
        ///
        /// M1's `CapturePolicy` already discards anything under a *peak* RMS of 0.01 before transcription, so
        /// what arrives here has at least one loud moment. This is the mean over the whole clip, and it sits an
        /// order of magnitude below ordinary dictation: a word actually spoken into the microphone clears it
        /// comfortably, while room tone that happened to contain one click does not.
        public var quietAudio: Double

        public init(
            noSpeech: Double = 0.6,
            certainNoSpeech: Double = 0.9,
            repeats: Int = 4,
            quietAudio: Double = 0.01
        ) {
            self.noSpeech = noSpeech
            self.certainNoSpeech = certainNoSpeech
            self.repeats = repeats
            self.quietAudio = quietAudio
        }

        public static let standard = Thresholds()
    }

    public enum Rejection: String, Sendable, CaseIterable {
        /// Nothing but whitespace, punctuation or annotations.
        case blank
        /// A training-set phrase.
        case artefact
        /// A token or a short run of tokens on a loop.
        case repetition
        /// whisper is certain there was no speech, whatever it decoded.
        case noSpeech = "no_speech"
    }

    public enum Verdict: Sendable, Equatable {
        /// The text to use, with annotations removed and whitespace collapsed.
        case keep(String)
        case reject(Rejection)
    }

    public let thresholds: Thresholds

    public init(thresholds: Thresholds = .standard) {
        self.thresholds = thresholds
    }

    /// `audioLevel` is the mean RMS of the clip as captured, before padding. Nil means the caller has no
    /// measurement, and the weak-filler rule then falls back to `no_speech_prob` alone.
    public func verdict(for text: String, noSpeechProbability: Double, audioLevel: Double? = nil) -> Verdict {
        let cleaned = Self.strippingAnnotations(text)
        let tokens = Self.fold(cleaned).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return .reject(.blank) }
        guard noSpeechProbability < thresholds.certainNoSpeech else { return .reject(.noSpeech) }

        let folded = tokens.joined(separator: " ")
        // Credits are matched anywhere in the utterance: once whisper has drifted into its subtitle training set,
        // the words around the credit are not worth trusting either.
        let padded = " \(folded) "
        if Self.credits.contains(where: { padded.contains(" \($0) ") }) { return .reject(.artefact) }
        if Self.silenceArtefacts.contains(folded) { return .reject(.artefact) }
        if isRepetitive(tokens) { return .reject(.repetition) }
        if Self.weakArtefacts.contains(folded), wasProbablySilent(noSpeechProbability, audioLevel) {
            return .reject(.artefact)
        }
        return .keep(cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    /// Whether anything other than whisper's word suggests the clip held no speech. Either signal is enough:
    /// they fail in different directions, and a weak filler is cheap to lose and expensive to keep.
    private func wasProbablySilent(_ noSpeechProbability: Double, _ audioLevel: Double?) -> Bool {
        if noSpeechProbability >= thresholds.noSpeech { return true }
        guard let audioLevel else { return false }
        return audioLevel < thresholds.quietAudio
    }

    /// True when the tokens are one token, or one short run of tokens, repeated `thresholds.repeats` times.
    func isRepetitive(_ tokens: [String]) -> Bool {
        guard thresholds.repeats >= 2 else { return false }
        if tokens.count >= thresholds.repeats {
            var run = 1
            for (previous, token) in zip(tokens, tokens.dropFirst()) {
                run = token == previous ? run + 1 : 1
                if run >= thresholds.repeats { return true }
            }
        }
        // "je vais je vais je vais je vais": no two neighbours are equal, but the whole text is one unit on a
        // loop. A trailing partial copy still counts, because whisper's loop is usually cut off by the clip.
        guard tokens.count >= 2 else { return false }
        for length in 1...(tokens.count / 2) {
            guard tokens.count / length >= copiesNeeded(forBlockOf: length) else { continue }
            let unit = Array(tokens.prefix(length))
            if tokens.enumerated().allSatisfy({ $1 == unit[$0 % length] }) { return true }
        }
        return false
    }

    /// How many consecutive copies of a block of `length` tokens make it a loop rather than speech.
    ///
    /// It has to scale with the block, because the two ends mean different things. One word twice is ordinary
    /// ("very very", "non non"), so a single token needs `thresholds.repeats` copies before it counts. A whole
    /// clause coming back a second time is not ordinary: whisper's decoder falls into a loop and re-emits the
    /// sentence it just wrote. Measured on this project, a nine-word sentence spoken once decoded twice, and the
    /// old rule could not see it — it only ever looked at blocks up to a quarter of the text.
    private func copiesNeeded(forBlockOf length: Int) -> Int {
        switch length {
        case 1: thresholds.repeats
        case 2...3: max(3, thresholds.repeats - 1)
        default: 2
        }
    }

    // MARK: Text

    /// Openers whose span is always an annotation, whatever it holds: whisper writes `[BLANK_AUDIO]` and quotes
    /// lyrics between eighth notes, and neither can be dictated.
    private static let unconditionalSpans: [Character: Character] = ["[": "]", "\u{266A}": "\u{266A}"]
    /// Openers whose span is an annotation only when it reads like one, because a speaker can dictate parentheses.
    private static let conditionalSpans: [Character: Character] = ["(": ")", "*": "*"]
    private static let annotationWords: Set<String> = [
        "music", "musique", "applause", "applaudissements", "laughter", "laughs", "laughing", "rires", "rire",
        "silence", "inaudible", "audio", "noise", "bruit", "sighs", "soupir", "coughs", "tousse", "sniffles",
        "beep", "bip", "vent", "wind", "static", "subtitles", "titres", "captioning",
    ]

    /// Phrases whisper produces only when it has run out of speech. Matched against the whole utterance.
    private static let silenceArtefacts: Set<String> = Set(
        [
            "thank you", "thank you very much", "thanks", "thanks a lot", "thank you so much",
            "thanks for watching", "thank you for watching", "thanks for watching everyone",
            "please subscribe", "subscribe to my channel", "like and subscribe", "see you next time",
            "the end", "bye bye", "goodbye everyone", "blank audio", "music playing", "silence",
            "merci", "merci beaucoup", "merci a tous", "merci de votre attention", "merci et a bientot",
            "abonnez vous", "a la prochaine", "au revoir et a bientot", "n oubliez pas de vous abonner",
            "generique", "generique de fin", "musique", "musique de fin", "fin de la video",
        ].map(fold))

    /// Subtitle credits. Matched anywhere in the utterance, not just as the whole of it.
    private static let credits: [String] = [
        "sous titrage societe radio canada", "sous titrage st 501", "sous titrage mfp",
        "sous titres realises par la communaute d amara org", "sous titres realises par",
        "merci d avoir regarde cette video", "merci d avoir regarde la video",
        "subtitles by the amara org community", "subtitled by", "transcription by castingwords",
        "amara org", "captions by",
    ].map(fold)

    /// Fillers whisper invents on near-silence that a person could also have said. Rejected only when
    /// `no_speech_prob` agrees, and only as the whole utterance.
    private static let weakArtefacts: Set<String> = Set(
        [
            "you", "so", "oh", "ok", "okay", "yeah", "yes", "no", "hmm", "mhm", "uh", "um", "right", "well",
            "bye", "hello", "hi", "and", "the", "a",
            "oui", "non", "euh", "bon", "bien", "voila", "et voila", "ah", "hein", "alors", "salut",
            "au revoir", "a bientot", "bonjour", "bonsoir", "d accord",
        ].map(fold))

    /// Lowercased, diacritic-free, alphanumeric words joined by single spaces. `Normalizer` (M6) is the
    /// user-facing one and does more; this only has to make the tables above match what whisper wrote.
    static func fold(_ text: String) -> String {
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        let separated = folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " " as Character
        }
        return String(separated).split(separator: " ").joined(separator: " ")
    }

    /// Removes annotation spans. An opener with no closer is literal text, so "(" alone survives.
    static func strippingAnnotations(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let closer = unconditionalSpans[character] ?? conditionalSpans[character]
            guard let closer else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            let contentStart = text.index(after: index)
            guard let closeIndex = text[contentStart...].firstIndex(of: closer) else {
                output.append(character)
                index = contentStart
                continue
            }
            let content = String(text[contentStart..<closeIndex])
            if unconditionalSpans[character] != nil || isAnnotation(content) {
                output.append(" ")
            } else {
                output.append(character)
                output.append(content)
                output.append(closer)
            }
            index = text.index(after: closeIndex)
        }
        return output
    }

    private static func isAnnotation(_ content: String) -> Bool {
        fold(content).split(separator: " ").contains { annotationWords.contains(String($0)) }
    }
}
