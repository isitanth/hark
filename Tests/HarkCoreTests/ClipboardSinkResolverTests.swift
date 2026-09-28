import HarkCore
import Testing

@Suite struct ClipboardSinkResolverTests {
    /// Until M6 matches commands, this is what fills the log's `normalized_text`.
    @Test func everyTranscriptIsCopiedWithItsNormalizedForm() async {
        let result = await ClipboardSinkResolver().resolve(Transcript(raw: "Ouvre le Finder."), focus: nil)
        #expect(result.normalized == Normalizer.normalize("Ouvre le Finder."))
        #expect(result.decision == .copy(.chosen))
    }
}
