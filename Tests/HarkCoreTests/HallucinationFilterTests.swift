import Foundation
import HarkCore
import Testing

struct VerdictCase: Sendable, CustomTestStringConvertible {
    let text: String
    var noSpeech: Double = 0.1
    /// Mean RMS of the clip. The default is ordinary dictation: loud enough that the quiet rule never fires.
    var level: Double = 0.08
    let rejection: HallucinationFilter.Rejection?

    var testDescription: String {
        let outcome = rejection.map(\.rawValue) ?? "keep"
        return "\(outcome) <- \"\(text)\" @ no_speech \(noSpeech), rms \(level)"
    }
}

/// Training-set artefacts whisper emits on silence, in both shipping languages.
let artefactCases: [VerdictCase] = [
    .init(text: "Thank you.", rejection: .artefact),
    .init(text: "Thanks for watching!", rejection: .artefact),
    .init(text: " Thank you for watching. ", rejection: .artefact),
    .init(text: "Please subscribe", rejection: .artefact),
    .init(text: "Like and subscribe", rejection: .artefact),
    .init(text: "See you next time.", rejection: .artefact),
    .init(text: "Bye bye.", rejection: .artefact),
    .init(text: "Merci.", rejection: .artefact),
    .init(text: "Merci beaucoup !", rejection: .artefact),
    .init(text: "Merci à tous.", rejection: .artefact),
    .init(text: "Merci de votre attention.", rejection: .artefact),
    .init(text: "Abonnez-vous !", rejection: .artefact),
    .init(text: "N'oubliez pas de vous abonner.", rejection: .artefact),
    .init(text: "À la prochaine.", rejection: .artefact),
    .init(text: "Générique de fin", rejection: .artefact),
    .init(text: "Sous-titrage Société Radio-Canada", rejection: .artefact),
    .init(text: "Sous-titrage ST' 501", rejection: .artefact),
    .init(text: "Sous-titres réalisés par la communauté d'Amara.org", rejection: .artefact),
    .init(text: "Merci d'avoir regardé cette vidéo !", rejection: .artefact),
    .init(text: "Subtitles by the Amara.org community", rejection: .artefact),
    // A credit is rejected wherever it sits: once whisper is quoting subtitles, the rest is not speech either.
    .init(text: "Bonjour, sous-titrage Société Radio-Canada, merci", rejection: .artefact),
]

/// Real dictation, including phrases that share words with the tables above.
let speechCases: [VerdictCase] = [
    .init(text: "open finder", rejection: nil),
    .init(text: "ouvre le Finder", rejection: nil),
    .init(text: "Thank you for the review, I will merge it tomorrow.", rejection: nil),
    .init(text: "Merci de relire la note avant jeudi.", rejection: nil),
    .init(text: "abonnez-vous à la liste de diffusion interne", rejection: nil),
    .init(text: "the end of the quarter is next week", rejection: nil),
    .init(text: "silence the alerts on the staging cluster", rejection: nil),
    // Loud and clear, so the weak-filler table does not apply.
    .init(text: "Yes", noSpeech: 0.05, rejection: nil),
    .init(text: "Oui", noSpeech: 0.05, rejection: nil),
    .init(text: "D'accord", noSpeech: 0.05, rejection: nil),
]

/// Fillers whisper invents on near-silence, which are also things a person says. Either a high `no_speech_prob`
/// or a clip too quiet to have carried the word is enough to reject one.
///
/// The `no_speech 0.0` rows are the ones that matter: fed two seconds of digital silence, whisper small returns
/// "you" with a `no_speech_prob` of 0.00000032. It is confidently wrong, so the audio level has to carry the
/// decision on its own.
let weakArtefactCases: [VerdictCase] = [
    .init(text: "You", noSpeech: 0.75, rejection: .artefact),
    .init(text: "So.", noSpeech: 0.6, rejection: .artefact),
    .init(text: "Okay.", noSpeech: 0.8, rejection: .artefact),
    .init(text: "Bye.", noSpeech: 0.7, rejection: .artefact),
    .init(text: "Euh...", noSpeech: 0.7, rejection: .artefact),
    .init(text: "Voilà.", noSpeech: 0.7, rejection: .artefact),
    .init(text: "Au revoir.", noSpeech: 0.7, rejection: .artefact),
    .init(text: "Bonjour.", noSpeech: 0.7, rejection: .artefact),
    // Whisper sure of itself over a silent room: rejected on the level alone.
    .init(text: "You", noSpeech: 0.0, level: 0.0, rejection: .artefact),
    .init(text: "You", noSpeech: 0.0000003, level: 0.002, rejection: .artefact),
    .init(text: "Okay.", noSpeech: 0.0, level: 0.009, rejection: .artefact),
    // The same words actually spoken, which is what the level is there to protect.
    .init(text: "You", noSpeech: 0.59, level: 0.08, rejection: nil),
    .init(text: "Okay.", noSpeech: 0.0, level: 0.05, rejection: nil),
    .init(text: "Voilà.", noSpeech: 0.5, level: 0.011, rejection: nil),
]

/// Whisper's decoder looping. The long ones were dictated once and came back twice.
let repetitionCases: [VerdictCase] = [
    // Observed 2026-09-21: said once into the microphone, decoded twice over 7.8 s.
    .init(
        text: "I'm just trying to understand if this works properly. "
            + "I'm just trying to understand if this works properly.",
        rejection: .repetition),
    .init(text: "je vais je vais je vais je vais", rejection: .repetition),
    .init(text: "ouvre le finder ouvre le finder ouvre le finder", rejection: .repetition),
    // Two words twice is not enough to call it: people repeat themselves for emphasis.
    .init(text: "très très bien", rejection: nil),
    .init(text: "no no thanks", rejection: nil),
    // A doubled phrase that is not actually periodic stays speech.
    .init(text: "to be or not to be", rejection: nil),
    .init(text: "open the log and then open the other one", rejection: nil),
]

let annotationCases: [VerdictCase] = [
    .init(text: "[BLANK_AUDIO]", rejection: .blank),
    .init(text: " [ Silence ] ", rejection: .blank),
    .init(text: "(music)", rejection: .blank),
    .init(text: "(Musique)", rejection: .blank),
    .init(text: "[Applause]", rejection: .blank),
    .init(text: "(applaudissements)", rejection: .blank),
    .init(text: "*rires*", rejection: .blank),
    .init(text: "\u{266A} la la la \u{266A}", rejection: .blank),
    .init(text: "", rejection: .blank),
    .init(text: "   \n\t ", rejection: .blank),
    .init(text: "...", rejection: .blank),
    .init(text: "- - -", rejection: .blank),
    // The annotation goes, the speech stays.
    .init(text: "[BLANK_AUDIO] open finder", rejection: nil),
]

@Suite struct HallucinationFilterTests {
    let filter = HallucinationFilter()

    @Test(arguments: artefactCases + speechCases + weakArtefactCases + repetitionCases + annotationCases)
    func verdictMatchesTheTable(_ expected: VerdictCase) {
        let verdict = filter.verdict(
            for: expected.text, noSpeechProbability: expected.noSpeech, audioLevel: expected.level)
        switch (verdict, expected.rejection) {
        case (.reject(let reason), .some(let wanted)):
            #expect(reason == wanted, "\(expected.testDescription)")
        case (.keep(let kept), .none):
            #expect(!kept.isEmpty, "\(expected.testDescription)")
        default:
            Issue.record("\(expected.testDescription) got \(verdict)")
        }
    }

    @Test func certainSilenceOverridesAnyText() {
        // Even a phrase that reads like dictation is rejected when whisper says there was nothing to hear.
        #expect(filter.verdict(for: "open finder", noSpeechProbability: 0.9) == .reject(.noSpeech))
        #expect(filter.verdict(for: "open finder", noSpeechProbability: 0.999) == .reject(.noSpeech))
        #expect(filter.verdict(for: "open finder", noSpeechProbability: 0.899) == .keep("open finder"))
    }

    @Test(arguments: [
        "you you you you",
        "You you you you you.",
        "je vais je vais je vais je vais",
        "la la la la la la",
        "merci merci merci merci merci merci",
        "test test test test",
    ])
    func repeatedTokensAreALoop(_ text: String) {
        #expect(filter.verdict(for: text, noSpeechProbability: 0.1) == .reject(.repetition))
    }

    @Test(arguments: [
        "you you you",
        "non non non",
        "very very very good",
        "open finder open finder",
        "c'est tout ce que j'avais à dire pour le moment",
    ])
    func shortRunsAreNotALoop(_ text: String) {
        guard case .keep = filter.verdict(for: text, noSpeechProbability: 0.1) else {
            Issue.record("\(text) was rejected")
            return
        }
    }

    @Test func theKeptTextKeepsCaseAndAccentsAndLosesTheAnnotation() {
        #expect(
            filter.verdict(for: "  Ouvre   le Finder,\ns'il te plaît. ", noSpeechProbability: 0.2)
                == .keep("Ouvre le Finder, s'il te plaît."))
        #expect(
            filter.verdict(for: "[BLANK_AUDIO] Démarre le VPN", noSpeechProbability: 0.2)
                == .keep("Démarre le VPN"))
        // A dictated parenthesis is text, not an annotation.
        #expect(
            filter.verdict(for: "open the file (the second one)", noSpeechProbability: 0.2)
                == .keep("open the file (the second one)"))
        // An opener with no closer is literal.
        #expect(filter.verdict(for: "the (second file", noSpeechProbability: 0.2) == .keep("the (second file"))
    }

    /// Without a measurement the rule falls back to whisper's opinion, so a caller that skips the level gets
    /// the old, weaker behaviour rather than a silent rejection of every short utterance.
    @Test func anUnmeasuredClipFallsBackToNoSpeechAlone() {
        #expect(filter.verdict(for: "You", noSpeechProbability: 0.0) == .keep("You"))
        #expect(filter.verdict(for: "You", noSpeechProbability: 0.75) == .reject(.artefact))
    }

    @Test func thresholdsAreConfigurable() {
        let strict = HallucinationFilter(thresholds: .init(noSpeech: 0.2, certainNoSpeech: 0.5, repeats: 3))
        #expect(strict.verdict(for: "Okay.", noSpeechProbability: 0.25) == .reject(.artefact))
        #expect(strict.verdict(for: "open finder", noSpeechProbability: 0.6) == .reject(.noSpeech))
        #expect(strict.verdict(for: "you you you", noSpeechProbability: 0.1) == .reject(.repetition))
        // The same inputs survive the standard thresholds.
        #expect(filter.verdict(for: "Okay.", noSpeechProbability: 0.25) == .keep("Okay."))
        #expect(filter.verdict(for: "open finder", noSpeechProbability: 0.6) == .keep("open finder"))
    }

    @Test func aRejectedUtteranceProducesABlankTranscript() {
        // The contract the pipeline depends on: a rejection is empty text, so it logs discarded/empty_transcript
        // instead of a fake command.
        for text in ["Thank you.", "Sous-titrage Société Radio-Canada", "[BLANK_AUDIO]", "(music)"] {
            guard case .reject = filter.verdict(for: text, noSpeechProbability: 0.1) else {
                Issue.record("\(text) survived")
                continue
            }
        }
    }
}
