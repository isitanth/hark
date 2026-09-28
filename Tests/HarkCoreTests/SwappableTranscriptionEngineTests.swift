import Foundation
import HarkCore
import Testing

@Suite struct SwappableTranscriptionEngineTests {
    /// Records what it was asked to do, so a swap can be observed from the outside.
    private actor SpyEngine: TranscriptionEngine {
        let reply: String
        private(set) var unloaded = false
        private(set) var transcribeCount = 0

        init(reply: String) {
            self.reply = reply
        }

        func transcribe(_ samples: [Float]) async throws(PipelineFailure) -> Transcript {
            transcribeCount += 1
            return Transcript(raw: reply)
        }

        func cancel() async {}

        func unload() async {
            unloaded = true
        }
    }

    @Test func aMissingModelFailsUntilOneIsSet() async throws {
        let engine = SwappableTranscriptionEngine()
        await #expect(throws: PipelineFailure.modelMissing(.small)) {
            try await engine.transcribe([0])
        }

        await engine.replace(with: SpyEngine(reply: "hello"))
        #expect(try await engine.transcribe([0]).raw == "hello")
    }

    @Test func replacingUnloadsTheEngineItReplaces() async throws {
        let first = SpyEngine(reply: "first")
        let second = SpyEngine(reply: "second")
        let engine = SwappableTranscriptionEngine(first)

        _ = try await engine.transcribe([0])
        await engine.replace(with: second)
        _ = try await engine.transcribe([0])

        #expect(await first.unloaded)
        #expect(await first.transcribeCount == 1)
        #expect(await second.unloaded == false)
        #expect(await second.transcribeCount == 1)
    }

    /// The default on the protocol is what lets an engine holding no model ignore the call.
    @Test func anEngineWithNoModelIgnoresUnload() async {
        let engine = SwappableTranscriptionEngine(NullTranscriptionEngine(tier: .large))
        await engine.unload()
        await #expect(throws: PipelineFailure.modelMissing(.large)) {
            try await engine.transcribe([0])
        }
    }
}
