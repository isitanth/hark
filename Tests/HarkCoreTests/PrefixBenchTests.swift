import Foundation
import HarkCore
import Testing

/// M9.0 (b): how whisper writes "Hark" at the start of a spoken request (docs/acceptance/M9.md).
///
///     HARK_TEST_MODEL=~/Library/Application\ Support/Hark/models/ggml-small-q8_0.bin \
///     HARK_TEST_PREFIX_BENCH=/path/to/out.jsonl swift test --filter PrefixBenchTests
///
/// `say` renders every request in five voices per language. Each clip goes through `Transcriber.transcribe`, the
/// app's own path with its padding and hallucination filter, under four settings: the one the app ships (language
/// auto, no vocabulary) and three what-ifs (the fixed language, and each with the vocabulary ["Hark"]). One JSON line
/// per decode goes to the file named by HARK_TEST_PREFIX_BENCH. Nothing is asserted: this measures.
///
/// Decoding is greedy at temperature 0, so a clip decodes the same way every time; the tries vary by sentence and
/// voice instead, and a few clips are decoded three times to show that. Synthetic speech is cleaner than a microphone:
/// these numbers are a floor for the real ones, which come from the user's own dictations.
enum PrefixBench {
    static let output = ProcessInfo.processInfo.environment["HARK_TEST_PREFIX_BENCH"]
    static var isAvailable: Bool { output != nil && TestModel.isAvailable }

    /// Unambiguous voice names: a bare "Eddy" or "Flo" exists in fourteen locales, and an unknown name falls back to
    /// the system voice without an error.
    static let voices: [TranscriptionLanguage: [String]] = [
        .english: ["Samantha", "Daniel", "Karen", "Moira", "Eddy (Anglais (É.-U.))"],
        .french: ["Thomas", "Jacques", "Amélie", "Eddy (Français (France))", "Flo (Français (France))"],
    ]

    /// Twenty requests per language. The last five have no comma, so `say` leaves no pause after the name.
    static let requests: [TranscriptionLanguage: [String]] = [
        .english: [
            "what is the capital of Peru?",
            "write an email to decline Thursday's meeting.",
            "how many days are left until Christmas?",
            "translate good morning into Spanish.",
            "give me three ideas for a birthday dinner.",
            "summarize the main causes of the First World War.",
            "what time is it in Tokyo right now?",
            "draft a short thank you note for my neighbour.",
            "explain how a heat pump works.",
            "suggest a title for my talk on network security.",
            "convert fifty miles into kilometres.",
            "write a polite reminder about the unpaid invoice.",
            "what is the difference between TCP and UDP?",
            "list the planets of the solar system.",
            "who painted the Mona Lisa?",
            "plan a three day trip to Lisbon",
            "how do I boil an egg properly",
            "write a short post announcing our new product",
            "what does the acronym DNS stand for",
            "tell me a joke about computers",
        ],
        .french: [
            "quelle est la capitale du Pérou ?",
            "écris un mail pour décliner la réunion de jeudi.",
            "combien de jours reste-t-il avant Noël ?",
            "traduis bonjour en espagnol.",
            "donne-moi trois idées de dîner d'anniversaire.",
            "résume les causes de la Première Guerre mondiale.",
            "quelle heure est-il à Tokyo en ce moment ?",
            "rédige un petit mot de remerciement pour ma voisine.",
            "explique comment fonctionne une pompe à chaleur.",
            "propose un titre pour ma présentation sur la sécurité réseau.",
            "convertis cinquante miles en kilomètres.",
            "écris une relance polie pour la facture impayée.",
            "quelle est la différence entre TCP et UDP ?",
            "fais la liste des planètes du système solaire.",
            "qui a peint la Joconde ?",
            "prépare un voyage de trois jours à Lisbonne",
            "comment faire cuire un œuf à la coque",
            "écris un court message pour annoncer notre nouveau produit",
            "que veut dire le sigle DNS",
            "raconte-moi une blague sur les ordinateurs",
        ],
    ]

    /// "Hark" on every request; "Hey Hark" on the first ten, to decide whether it earns a place as a second prefix.
    static let prefixes: [(name: String, spoken: String, count: Int)] = [
        ("hark", "Hark", 20),
        ("hey hark", "Hey Hark", 10),
    ]

    struct Setting: Sendable {
        let name: String
        let fixedLanguage: Bool
        let vocabulary: [String]
    }

    static let settings = [
        Setting(name: "shipped", fixedLanguage: false, vocabulary: []),
        Setting(name: "fixed", fixedLanguage: true, vocabulary: []),
        Setting(name: "vocabulary", fixedLanguage: false, vocabulary: ["Hark"]),
        Setting(name: "fixed+vocabulary", fixedLanguage: true, vocabulary: ["Hark"]),
    ]

    /// Clips decoded three times under the shipped setting, to show the decode is repeatable.
    static let repeats = 3
    static let repeatedClips = 2
}

@Suite(.enabled(if: PrefixBench.isAvailable), .serialized, .timeLimit(.minutes(30)))
struct PrefixBenchTests {
    struct Clip: Sendable {
        let language: TranscriptionLanguage
        let voice: String
        let prefix: String
        let index: Int
        let text: String
        let samples: [Float]
    }

    struct Line: Encodable {
        let setting: String
        let language: String
        let voice: String
        let prefix: String
        let index: Int
        let run: Int
        let text: String
        let raw: String
        let normalized: String
        let detected: String?
        let ms: Int?
        let rejected: Bool
    }

    @Test func measure() async throws {
        let path = try #require(PrefixBench.output)
        let directory = try TemporaryDirectory()
        let clips = try Self.render(in: directory)
        try #require(FileManager.default.createFile(atPath: path, contents: nil))
        let file = try #require(FileHandle(forWritingAtPath: path))
        defer { try? file.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let installation = try #require(TestModel.installation)

        for setting in PrefixBench.settings {
            let groups: [(TranscriptionLanguage, [Clip])] =
                setting.fixedLanguage
                ? [TranscriptionLanguage.english, .french].map { language in
                    (language, clips.filter { $0.language == language })
                }
                : [(.auto, clips)]
            for (language, group) in groups {
                let transcriber = Transcriber(
                    model: installation, language: language, vocabulary: setting.vocabulary)
                try await transcriber.prepare()
                for clip in group {
                    for run in 0..<Self.runs(of: clip, under: setting) {
                        let transcript = try await transcriber.transcribe(clip.samples)
                        let report = await transcriber.lastDecode
                        let line = Line(
                            setting: setting.name, language: clip.language.rawValue, voice: clip.voice,
                            prefix: clip.prefix, index: clip.index, run: run, text: clip.text,
                            raw: transcript.raw, normalized: Normalizer.normalize(transcript.raw),
                            detected: report?.languageCode, ms: report?.ms, rejected: report?.rejection != nil)
                        try file.write(contentsOf: encoder.encode(line) + Data("\n".utf8))
                    }
                }
                await transcriber.unload()
            }
        }
    }

    private static func runs(of clip: Clip, under setting: PrefixBench.Setting) -> Int {
        let firstVoice = PrefixBench.voices[clip.language]?.first
        let repeated = setting.name == "shipped" && clip.index < PrefixBench.repeatedClips && clip.voice == firstVoice
        return repeated ? PrefixBench.repeats : 1
    }

    private static func render(in directory: TemporaryDirectory) throws -> [Clip] {
        var clips: [Clip] = []
        for language in [TranscriptionLanguage.english, .french] {
            let requests = PrefixBench.requests[language] ?? []
            for prefix in PrefixBench.prefixes {
                for (index, request) in requests.prefix(prefix.count).enumerated() {
                    let text = index < 15 ? "\(prefix.spoken), \(request)" : "\(prefix.spoken) \(request)"
                    for voice in PrefixBench.voices[language] ?? [] {
                        let samples = try TestModel.speech(text, voice: voice, in: directory)
                        clips.append(
                            Clip(
                                language: language, voice: voice, prefix: prefix.name, index: index, text: text,
                                samples: samples))
                    }
                }
            }
        }
        return clips
    }
}
