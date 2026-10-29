import Foundation

// The plan request (M13, b1 §4): the measured plan prompt, the image first, the numbered cells and the words. Kept out
// of `AskPrompt`, whose strings stay byte for byte. S3 implements this.

public struct PlanPrompt: Sendable, Equatable {
    /// The frozen plan prompt, byte for byte.
    public static let system = ""
    /// The user turn's first line: longer than 23 characters and holding no user text.
    public static let leadLine = ""

    public let messages: [ChatMessage]

    public init(
        instruction: String, sheet: CellSheet, image: ImagePart?, selection: String?,
        maxSelectionChars: Int = LLMConfig.defaultMaxSelectionChars
    ) {
        messages = []
    }

    /// A computational follow-up, planned again over the conversation's latest sheet. Nil when a framed turn's image
    /// is missing: nothing is sent then.
    public static func thread(
        _ thread: AskThread, current: (instruction: String, image: ImagePart?), sheet: CellSheet,
        images: [UtteranceID: ImagePart], maxSelectionChars: Int = LLMConfig.defaultMaxSelectionChars
    ) -> PlanPrompt? {
        nil
    }

    /// The numbered cells as the model reads them, in the format that scored 20/20.
    public static func listing(_ sheet: CellSheet) -> String {
        ""
    }
}
