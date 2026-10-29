import Foundation

/// The environment's planner (M13): the plan prompt over the sheet's cells, under `CalculationPlan.schema`, with the
/// same profile, pin and gates as an answer. The reply is the plan's JSON, passed through as `text` pieces; the reducer
/// solves it, and it is never logged.
extension AskEngine: AskPlanning {
    public func plan(
        instruction: String, sheet: CellSheet, selection: String?, image: ImagePart?, thread: AskThread?,
        frames: [UtteranceID: ImagePart], correction: PlanCorrection?
    ) -> AsyncStream<LLMEvent> {
        request(thread: thread, image: image, format: CalculationPlan.schema) { llm in
            let prompt: PlanPrompt?
            if let thread {
                prompt = PlanPrompt.thread(
                    thread, current: (instruction, image), sheet: sheet, images: frames,
                    maxSelectionChars: llm.maxSelectionChars)
            } else {
                prompt = PlanPrompt(
                    instruction: instruction, sheet: sheet, image: image, selection: selection,
                    maxSelectionChars: llm.maxSelectionChars)
            }
            guard let prompt else { return nil }
            return (correction.map { PlanPrompt.retry(prompt, correction: $0) } ?? prompt).messages
        }
    }
}
