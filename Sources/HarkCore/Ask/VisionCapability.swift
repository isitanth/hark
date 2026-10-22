import Foundation
import os

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

/// What Hark has learned of whether a model reads images, in memory only: a server restart can load another pack, and
/// the next probe learns it again. Keyed by profile name, base URL and the model id an ask resolved; `nil` is
/// unknown, which sends and lets the server's answer decide.
public final class VisionCapability: Sendable {
    struct Key: Hashable, Sendable {
        let profile: String
        let baseURL: URL
        let model: String
    }

    /// What clears a profile's verdicts when it changes.
    struct Signature: Equatable, Sendable {
        let baseURL: URL
        let model: ModelChoice
        let api: ProviderAPI
    }

    private struct State: Sendable {
        var verdicts: [Key: Bool] = [:]
        var signatures: [String: Signature] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func verdict(profile: ProviderProfile, model: String) -> Bool? {
        state.withLock { $0.verdicts[Self.key(profile, model)] }
    }

    /// Nil forgets: a probe that says nothing of images leaves the verdict a refusal taught in place, so callers
    /// pass nil only to forget on purpose.
    public func record(_ verdict: Bool?, profile: ProviderProfile, model: String) {
        state.withLock { state in
            state.verdicts[Self.key(profile, model)] = verdict
            // The profile as it was when this was learned, so a change to it before the next `update` still clears it.
            if state.signatures[profile.name] == nil { state.signatures[profile.name] = Self.signature(profile) }
        }
    }

    /// A probe's report: its verdict for the model it connected to, when it has one.
    public func record(_ report: LLMProbeReport, profile: ProviderProfile) {
        guard case .connected(let model) = report.result, let vision = report.vision else { return }
        record(vision, profile: profile, model: model)
    }

    /// commands.yaml as it now reads: the verdicts of a profile whose `base_url`, `model` or `api` changed, or that
    /// is gone, are forgotten.
    public func update(_ config: LLMConfig) {
        state.withLock { state in
            let signatures = config.profiles.mapValues(Self.signature)
            let changed = Set(state.signatures.filter { signatures[$0.key] != $0.value }.keys)
            state.verdicts = state.verdicts.filter { !changed.contains($0.key.profile) }
            state.signatures = signatures
        }
    }

    private static func signature(_ profile: ProviderProfile) -> Signature {
        Signature(baseURL: profile.baseURL, model: profile.model, api: profile.api)
    }

    private static func key(_ profile: ProviderProfile, _ model: String) -> Key {
        Key(profile: profile.name, baseURL: profile.baseURL, model: model)
    }
}
