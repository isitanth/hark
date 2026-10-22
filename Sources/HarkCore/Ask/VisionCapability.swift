import Foundation

extension LLMFailure {
    /// A server's words that mean the model has no vision (report a5, §4), lowercased.
    static let noVisionPhrases = [
        "no vision tower", "image content is not supported", "image_url is only supported by certain models",
        "image input is not supported", "is not a multimodal model", "does not support images",
        "does not support image", "missing data required for image input", "only 'text' content type is supported",
        "no endpoints found that support image input",
    ]

    /// MTPLX in AR mode.
    static let needsMTPModePhrase = "image content requires mtp generation mode"

    /// An image the model could read but the server would not take: too large or malformed. Hark's own resize should
    /// make these unreachable; they stay `.server` so the log shows them as a bug.
    static let imageRefusedPhrases = [
        "image exceeds", "exceeds the 50mb limit", "image dimensions exceed", "image data url must be base64",
        "could not process image",
    ]

    /// The refusal of a request that carried an image, when its status and words say for certain that the model
    /// cannot read one; nil for anything else, which keeps the mapping of a request without an image.
    public static func imageRefusal(status: Int, message: String?, model: String?) -> LLMFailure? {
        guard [400, 404, 500].contains(status), let message else { return nil }
        let words = message.lowercased()
        if imageRefusedPhrases.contains(where: words.contains) { return nil }
        if words.contains(needsMTPModePhrase) { return .noVision(model: model, reason: .needsMTPMode) }
        if noVisionPhrases.contains(where: words.contains)
            || (words.contains("vision") && words.contains("not supported"))
        {
            return .noVision(model: model, reason: .noVision)
        }
        return nil
    }
}
