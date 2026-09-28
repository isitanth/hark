import HarkCore
import Testing

/// The log's `error` codes are a contract: a code once written reads back the same in every later build.
@Suite struct PipelineFailureCodeTests {
    static let askCodes: [(PipelineFailure, String)] = [
        (.llmUnreachable, "llm_unreachable"),
        (.llmUnauthorized, "llm_unauthorized"),
        (.llmTimeout, "llm_timeout"),
        (.llmError(status: 500), "llm_error:500"),
        (.llmError(status: 404), "llm_error:404"),
        (.llmError(status: nil), "llm_error"),
        (.llmEmpty, "llm_empty"),
        (.selectionChanged, "selection_changed"),
    ]

    @Test(arguments: askCodes)
    func theAskCodes(_ failure: PipelineFailure, _ code: String) {
        #expect(failure.code == code)
        #expect(!failure.isCaptureFailure)
    }

    @Test func theEmptySelectionDiscard() {
        #expect(DiscardReason.emptySelection.rawValue == "empty_selection")
        #expect(DiscardReason(rawValue: "empty_selection") == .emptySelection)
    }

    /// Every discard reason has its own code, so a line never reads back as another reason.
    @Test func theDiscardCodesAreDistinct() {
        let codes = DiscardReason.allCases.map(\.rawValue)
        #expect(Set(codes).count == codes.count)
    }
}
