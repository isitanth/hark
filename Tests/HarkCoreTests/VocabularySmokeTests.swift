import Foundation
import HarkCore
import Testing

/// The custom vocabulary against the real model, as measured for M3 (docs/acceptance/M3.md). Off unless
/// `HARK_TEST_MODEL` is set, like the other smoke tests. The speech is synthesized with `say`; its rendering varies a
/// little from run to run, so only outcomes that held across voices and speaking rates are asserted here.
@Suite(.enabled(if: TestModel.isAvailable), .serialized, .timeLimit(.minutes(2)))
struct VocabularySmokeTests {
    static let vocabulary = ["Hark", "Claude"]

    /// whisper can hand its prompt back, or invent text, when there is nothing to hear. With the labelled list it did
    /// neither, in any language mode; prose prompts did, under French.
    @Test(arguments: [TranscriptionLanguage.auto, .french, .english])
    func silenceWithAVocabularyStaysEmpty(_ language: TranscriptionLanguage) async throws {
        let transcriber = Transcriber(
            model: try #require(TestModel.installation), language: language, vocabulary: Self.vocabulary)
        let transcript = try await transcriber.transcribe([Float](repeating: 0, count: 32_000))
        #expect(transcript.raw.isEmpty, "silence decoded as \"\(transcript.raw)\"")
    }

    /// Without the vocabulary a French voice's "Hark" is "Arc"; the bare-list prompt made the English one "Harck".
    @Test(arguments: [
        ("Thomas", TranscriptionLanguage.french, "Hark est l'application de dictée que j'utilise."),
        ("Samantha", .english, "I asked Claude to review the Hark settings."),
    ])
    func theVocabularySpellsHark(_ voice: String, _ language: TranscriptionLanguage, _ text: String) async throws {
        let directory = try TemporaryDirectory()
        let transcriber = Transcriber(
            model: try #require(TestModel.installation), language: language, vocabulary: Self.vocabulary)
        try await transcriber.prepare()
        let transcript = try await transcriber.transcribe(try TestModel.speech(text, voice: voice, in: directory))
        #expect(transcript.raw.contains("Hark"), "\"\(transcript.raw)\"")
        #expect(!transcript.raw.contains("Harck"), "\"\(transcript.raw)\"")
    }
}
