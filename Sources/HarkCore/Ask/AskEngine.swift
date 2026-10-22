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

    /// A follow-up (`thread`) rebuilds the whole conversation, goes to the model turn 1 asked for, and only while the
    /// active profile is still the one turn 1 used: no probe, and nothing sent after a switch. `frames` holds the
    /// answered turns' images by turn; `image` is the current turn's.
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
                let prompt: AskPrompt
                if let thread {
                    guard thread.pin.matches(profile) else {
                        continuation.yield(.failed(.profileChanged, LLMCallSummary()))
                        return
                    }
                    model = thread.pin.requestedModel
                    guard
                        let built = AskPrompt.thread(
                            thread, current: (instruction, image), images: frames,
                            maxSelectionChars: llm.maxSelectionChars)
                    else {
                        continuation.yield(.failed(.frameMissing, LLMCallSummary()))
                        return
                    }
                    prompt = built
                } else {
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
                    if let image {
                        prompt = AskPrompt(
                            instruction: instruction, selection: selection, image: image,
                            maxSelectionChars: llm.maxSelectionChars)
                    } else {
                        prompt =
                            selection.map {
                                AskPrompt(
                                    instruction: instruction, selection: $0, maxSelectionChars: llm.maxSelectionChars)
                            } ?? AskPrompt(request: instruction)
                    }
                }
                // A frame in any turn makes this an image request, for the gate and for what it teaches.
                let hasImage = image != nil || prompt.messages.contains(where: \.hasImage)
                // Known blind: nothing is sent, and the panel says which model cannot see.
                if hasImage && vision.verdict(profile: profile, model: model) == false {
                    continuation.yield(.failed(.noVision(model: model, reason: .knownBeforeSending), LLMCallSummary()))
                    return
                }
                // Turn 1 tells the reducer where it went, so a follow-up can pin it.
                let pin = thread == nil ? ProfilePin(profile: profile, requestedModel: model) : nil
                var learned = false
                for await event in client.complete(prompt.messages, model: model, profile: profile) {
                    if hasImage && !learned {
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
                    switch event {
                    case .finished(var summary):
                        summary.pin = pin
                        continuation.yield(.finished(summary))
                    case .failed(let failure, var summary):
                        summary.pin = pin
                        continuation.yield(.failed(failure, summary))
                    case .text:
                        continuation.yield(event)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
