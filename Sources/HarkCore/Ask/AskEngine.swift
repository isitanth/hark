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
/// with the selection cut to the cap, then the streamed completion.
public struct AskEngine: AskGenerating {
    private let client: LLMClient
    private let settings: AskSettings

    public init(client: LLMClient, settings: AskSettings) {
        self.client = client
        self.settings = settings
    }

    public func generate(instruction: String, selection: String) -> AsyncStream<LLMEvent> {
        let llm = settings.current
        let client = client
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
                    switch await LLMProbe(client: client).check(profile) {
                    case .connected(let id): model = id
                    case .failed(let failure):
                        continuation.yield(.failed(failure, LLMCallSummary()))
                        return
                    }
                }
                let prompt = AskPrompt(
                    instruction: instruction, selection: selection, maxSelectionChars: llm.maxSelectionChars)
                for await event in client.complete(prompt.messages, model: model, profile: profile) {
                    continuation.yield(event)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
