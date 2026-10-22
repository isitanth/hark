import Foundation
import os

/// commands.yaml's `llm:` as the next ask reads it. HarkApp updates it when the file reloads.
public final class AskSettings: Sendable {
    private let lock: OSAllocatedUnfairLock<LLMConfig>

    public init(_ config: LLMConfig = .standard) {
        lock = OSAllocatedUnfairLock(initialState: config)
    }

    public var current: LLMConfig {
        lock.withLock { $0 }
    }

    public func update(_ config: LLMConfig) {
        lock.withLock { $0 = config }
    }
}

/// The pipeline's `AskGenerating`: the active profile, its model (named, or the first `GET /models` lists), the prompt
/// with the selection cut to the cap, then the streamed completion. An image goes only to a model not known to be
/// blind; what each image ask teaches about the model is kept in `vision`.
public struct AskEngine: AskGenerating {
    private let client: LLMClient
    private let settings: AskSettings
    public let vision: VisionCapability

    public init(client: LLMClient, settings: AskSettings, vision: VisionCapability = VisionCapability()) {
        self.client = client
        self.settings = settings
        self.vision = vision
    }

    /// A follow-up (`thread`) goes as a single ask until M12.2 builds its whole request.
    public func generate(
        instruction: String, selection: String?, image: ImagePart?, thread: AskThread?,
        frames: [UtteranceID: ImagePart]
    ) -> AsyncStream<LLMEvent> {
        let llm = settings.current
        let client = client
        let vision = vision
        vision.update(llm)
        return AsyncStream { continuation in
            let task = Task {
                defer { continuation.finish() }
                // The parser refuses a `provider` that names no profile, so this is a config built in code.
                guard let profile = llm.activeProfile else {
                    continuation.yield(.failed(.server(status: nil, message: nil), LLMCallSummary()))
                    return
                }
                let model: String
                switch profile.model {
                case .named(let id):
                    model = id
                case .auto:
                    let report = await LLMProbe(client: client).inspect(profile)
                    switch report.result {
                    case .connected(let id):
                        model = id
                        vision.record(report, profile: profile)
                    case .failed(let failure):
                        continuation.yield(.failed(failure, LLMCallSummary()))
                        return
                    }
                }
                let prompt: AskPrompt
                if let image {
                    // Known blind: nothing is sent, and the panel says which model cannot see.
                    if vision.verdict(profile: profile, model: model) == false {
                        continuation.yield(
                            .failed(.noVision(model: model, reason: .knownBeforeSending), LLMCallSummary()))
                        return
                    }
                    prompt = AskPrompt(
                        instruction: instruction, selection: selection, image: image,
                        maxSelectionChars: llm.maxSelectionChars)
                } else {
                    prompt =
                        selection.map {
                            AskPrompt(instruction: instruction, selection: $0, maxSelectionChars: llm.maxSelectionChars)
                        } ?? AskPrompt(request: instruction)
                }
                var learned = false
                for await event in client.complete(prompt.messages, model: model, profile: profile) {
                    if image != nil && !learned {
                        switch event {
                        case .text:
                            // The model read the image: it streamed an answer to it.
                            vision.record(true, profile: profile, model: model)
                            learned = true
                        case .failed(.noVision(_, .noVision), _):
                            vision.record(false, profile: profile, model: model)
                            learned = true
                        default: break
                        }
                    }
                    continuation.yield(event)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
