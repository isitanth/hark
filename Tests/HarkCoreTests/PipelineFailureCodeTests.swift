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
        (.llmNoVision, "llm_no_vision"),
        (.screenRecordingDenied, "screen_recording_denied"),
        (.regionFailed, "region_failed"),
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

    /// A model without eyes is its own code, whatever told Hark so; a region that did not become an image keeps its
    /// cause.
    @Test func theVisualContextFailures() {
        for reason in [VisionRefusal.noVision, .needsMTPMode, .knownBeforeSending] {
            #expect(LLMFailure.noVision(model: "bonsai", reason: reason).pipelineFailure == .llmNoVision)
        }
        #expect(RegionFailure.screenRecordingDenied.pipelineFailure.code == "screen_recording_denied")
        #expect(RegionFailure.captureFailed.pipelineFailure.code == "region_failed")
    }

    /// Every discard reason has its own code, so a line never reads back as another reason.
    @Test func theDiscardCodesAreDistinct() {
        let codes = DiscardReason.allCases.map(\.rawValue)
        #expect(Set(codes).count == codes.count)
    }

    /// Exact math's three families (M13): a reason after the colon, never content.
    static let exactCodes: [(PipelineFailure, String)] =
        ReaderFailure.allCases.map { (.readerFailed($0), "reader_failed:\($0.rawValue)") }
        + [
            (.planInvalid(.json), "plan_invalid:json"),
            (.planInvalid(.truncated), "plan_invalid:truncated"),
            (.planInvalid(.syntax), "plan_invalid:syntax"),
            (.planInvalid(.unknownFunction), "plan_invalid:unknown_function"),
            (.planInvalid(.unknownCell), "plan_invalid:unknown_cell"),
            (.planInvalid(.unspokenConstant("0.2")), "plan_invalid:unspoken_constant"),
            (.planInvalid(.noFormula), "plan_invalid:no_formula"),
            (.planInvalid(.unit), "plan_invalid:unit"),
            (.planInvalid(.degenerate), "plan_invalid:degenerate"),
        ]
        + MathDefect.allCases.map { (.mathError($0), "math_error:\($0.rawValue)") }

    @Test(arguments: exactCodes)
    func theExactMathCodes(_ failure: PipelineFailure, _ code: String) {
        #expect(failure.code == code)
        #expect(!failure.isCaptureFailure)
    }

    @Test func theExactMathReasons() {
        #expect(ReaderFailure.allCases.map(\.rawValue) == ["vision", "timeout"])
        #expect(MathDefect.allCases.map(\.rawValue) == ["division_by_zero", "no_number", "garbled", "overflow"])
    }

    /// The failing cell is the panel's, never the log's; a server that refuses the schema is a plan that is not JSON.
    @Test func theExactMathFailuresMapToTheirCodes() {
        #expect(MathFailure.reader(.timeout).pipelineFailure.code == "reader_failed:timeout")
        #expect(MathFailure.plan(.unspokenConstant("12")).pipelineFailure.code == "plan_invalid:unspoken_constant")
        #expect(MathFailure.math(.noNumber, cell: CellID(7)).pipelineFailure.code == "math_error:no_number")
        #expect(MathFailure.math(.overflow, cell: nil).pipelineFailure.code == "math_error:overflow")
        #expect(LLMFailure.formatRefused(model: "gemma").pipelineFailure.code == "plan_invalid:json")
    }
}
