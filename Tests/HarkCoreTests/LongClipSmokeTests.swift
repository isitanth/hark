import Foundation
import HarkCore
import Testing

/// Speech past whisper's 30 s window, decoded chunk by chunk, against the real model. Off unless `HARK_TEST_MODEL` is
/// set, like the other smoke tests; the speech is synthesized with `say`.
///
/// Before the chunks, one `whisper_full` over the whole clip returned the first 30 s of the French text below and
/// "Je amuse." for the rest, and a 15 s pause turned what followed into English. So the words checked are spread
/// over the whole clip, one or two per chunk at least, and the last one is at the very end.
@Suite(.enabled(if: TestModel.isAvailable), .serialized, .timeLimit(.minutes(3)))
struct LongClipSmokeTests {
    static let french = """
        Bonjour, je voudrais faire le point sur la réunion de ce matin avant que tout le monde parte en week-end. \
        Nous avons parlé du budget pour le trimestre prochain, et il faudra revoir les dépenses liées aux \
        déplacements, parce qu'elles ont presque doublé depuis le printemps. Julien propose de regrouper les visites \
        chez les clients sur deux jours par mois, ce qui réduirait les frais de train et d'hôtel. Marie n'est pas \
        d'accord, elle pense que les clients les plus importants attendent une présence plus régulière, et qu'une \
        visite par mois ne suffit pas. Il faudrait donc trouver un compromis, peut-être en gardant des visites \
        fréquentes pour les cinq plus gros comptes et en passant les autres en visioconférence. Ensuite, nous avons \
        abordé le recrutement. Deux postes sont ouverts depuis juillet et nous n'avons reçu que très peu de \
        candidatures sérieuses. Le cabinet de recrutement nous a conseillé d'augmenter légèrement la fourchette de \
        salaire et de mieux décrire les missions dans l'annonce. Je pense que c'est une bonne idée, mais il faut \
        d'abord en parler avec la direction financière. Enfin, le déménagement des bureaux est toujours prévu pour \
        la fin de l'année. Les plans du nouvel étage sont presque prêts, et chacun pourra choisir sa place la \
        semaine prochaine. Merci à tous pour votre travail, et bon week-end.
        """
    static let english = """
        Hello everyone, I wanted to summarize this morning's meeting before the weekend. We talked about the budget \
        for next quarter, and we will need to review travel expenses, because they have almost doubled since the \
        spring. Julian suggests grouping customer visits into two days a month, which would cut train and hotel \
        costs. Mary disagrees; she thinks our most important customers expect a more regular presence, and that one \
        visit a month is not enough. So we need to find a compromise, perhaps keeping frequent visits for the five \
        largest accounts and moving the others to video calls. Then we discussed hiring. Two positions have been \
        open since July and we have received very few serious applications. The recruiting firm advised us to raise \
        the salary range slightly and to describe the role more clearly in the job posting. I think that is a good \
        idea, but we should talk to the finance team first. Finally, the office move is still planned for the end \
        of the year. The floor plans are almost ready, and everyone will be able to choose a desk next week. Thank \
        you all for your work, and have a good weekend.
        """
    static let frenchMarks = ["reunion", "julien", "compromis", "visio", "candidatures", "nouvel etage", "week end"]
    static let englishMarks = [
        "meeting", "julian", "compromise", "video calls", "applications", "floor plans", "weekend",
    ]

    @Test func aLongFrenchDictationComesBackWhole() async throws {
        let samples = try TestModel.speech(Self.french, voice: "Thomas", in: try TemporaryDirectory())
        try await expectWhole(samples, marks: Self.frenchMarks, language: "fr")
    }

    @Test func aLongEnglishDictationComesBackWhole() async throws {
        let samples = try TestModel.speech(Self.english, voice: "Samantha", in: try TemporaryDirectory())
        try await expectWhole(samples, marks: Self.englishMarks, language: "en")
    }

    /// 15 s of silence in the middle, as when you stop to think with the key latched. The silence goes in at 35 s,
    /// through a word, so the words either side of it ("comptes", "visioconférence") are not checked.
    @Test func aLongPauseInTheMiddleLosesNothingAfterIt() async throws {
        let speech = try TestModel.speech(Self.french, voice: "Thomas", in: try TemporaryDirectory())
        let cut = 35 * Int(SampleBuffer.sampleRate)
        let silence = [Float](repeating: 0, count: 15 * Int(SampleBuffer.sampleRate))
        try await expectWhole(
            Array(speech[..<cut]) + silence + Array(speech[cut...]),
            marks: Self.frenchMarks.filter { $0 != "visio" }, language: "fr")
    }

    /// Key up on a cancel while a long final decodes: whisper reads the abort between graph computes and the clip's
    /// later chunks are never started, so the call returns within one chunk rather than after all of them.
    @Test func aCancelMidwayReturnsWithinOneChunk() async throws {
        let samples = try TestModel.speech(Self.french, voice: "Thomas", in: try TemporaryDirectory())
        let transcriber = Transcriber(model: try #require(TestModel.installation), language: .auto)
        try await transcriber.prepare()
        let clock = ContinuousClock()

        let full = try await clock.measure { _ = try await transcriber.transcribe(samples) }
        let started = clock.now
        let decode = Task { try await transcriber.transcribe(samples) }
        try await Task.sleep(for: .milliseconds(300))
        await transcriber.cancel()
        let transcript = try await decode.value
        let cancelled = started.duration(to: clock.now)

        #expect(transcript.raw.isEmpty, "an aborted decode comes back blank")
        #expect(cancelled < full / 2, "cancelled after 300 ms, returned at \(cancelled); a full decode took \(full)")
        Issue.record(Comment(rawValue: "cancel: returned at \(cancelled), full decode \(full)"), severity: .warning)
    }

    private func expectWhole(_ samples: [Float], marks: [String], language: String) async throws {
        try #require(samples.count > 2 * ClipChunks.maximumSampleCount, "the clip must span three windows")
        let transcriber = Transcriber(model: try #require(TestModel.installation), language: .auto)
        let transcript = try await transcriber.transcribe(samples)

        let report = try #require(await transcriber.lastDecode)
        let heard = Self.fold(transcript.raw)
        #expect(report.chunks >= 3 && report.keptChunks >= 3, "\(report.keptChunks) of \(report.chunks) chunks kept")
        #expect(report.languageCode == language)
        for mark in marks {
            #expect(heard.contains(mark), "\"\(mark)\" missing from: \(transcript.raw)")
        }
    }

    /// Lowercased, without diacritics, words joined by single spaces.
    private static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }
}
