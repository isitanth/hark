import Foundation
import HarkCore
import Testing

private typealias F = Fixture

@Suite(.timeLimit(.minutes(1)))
struct PipelineControllerTests {
    private func next(
        _ iterator: inout AsyncStream<PipelineSnapshot>.Iterator, where condition: (PipelineSnapshot) -> Bool
    ) async -> PipelineSnapshot? {
        while let snapshot = await iterator.next() {
            if condition(snapshot) { return snapshot }
        }
        return nil
    }

    private func makeController(
        _ directory: TemporaryDirectory, workspace: any Workspace, audio: ScriptedAudioInput = .init(summary: F.speech)
    ) -> (PipelineController, UtteranceLog) {
        let log = UtteranceLog(directory: directory.url, timeZone: F.paris)
        let environment = PipelineEnvironment(
            workspace: workspace,
            pasteboard: DiscardingPasteboard(),
            clock: ManualWallClock(F.pressedAt),
            audio: audio,
            engine: NullTranscriptionEngine(tier: .small))
        return (PipelineController(environment: environment, log: log), log)
    }

    private func lines(_ log: UtteranceLog) throws -> [String] {
        try String(contentsOf: log.fileURL(for: F.pressedAt), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test(arguments: [
        (AudioInputEvent.reachedMaxDuration(F.id, F.maxed), "failed", "model_missing:small"),
        (.interrupted(F.id, .deviceChanged), "failed", "device_changed"),
    ])
    func captureThatEndsOnItsOwnLogsOnceAndIgnoresTheRelease(
        _ event: AudioInputEvent, _ resolution: String, _ error: String
    ) async throws {
        let directory = try TemporaryDirectory()
        let audio = ScriptedAudioInput(summary: F.speech)
        let (controller, log) = makeController(
            directory, workspace: await MainActorWorkspace(app: F.mail), audio: audio)
        var snapshots = controller.snapshots.makeAsyncIterator()

        await controller.triggerDown()
        _ = await next(&snapshots) { $0.utterance?.focus != nil }
        audio.emit(event)
        let done = await next(&snapshots) { $0.phase == .idle && $0.lastRecord != nil }
        await controller.triggerUp()

        #expect(done?.lastRecord?.resolution.rawValue == resolution)
        #expect(done?.lastRecord?.error == error)
        #expect(await controller.phase == .idle)
        #expect(try lines(log).count == 1)
    }

    /// The seam isolation proof: a `@MainActor` implementation of an async seam, called from the controller actor.
    @Test func mainActorSeamIsCalledFromTheController() async throws {
        let directory = try TemporaryDirectory()
        let workspace = await MainActorWorkspace(app: F.mail)
        let (controller, log) = makeController(directory, workspace: workspace)
        var snapshots = controller.snapshots.makeAsyncIterator()

        await controller.triggerDown()
        _ = await next(&snapshots) { $0.utterance?.focus != nil }
        await controller.triggerUp()
        let done = await next(&snapshots) { $0.phase == .idle && $0.lastRecord != nil }

        let record = try #require(done?.lastRecord)
        #expect(record.targetApp == "com.apple.mail")
        #expect(record.resolution == .failed)
        #expect(record.error == "model_missing:small")
        #expect(record.durationMs == 1800)
        #expect(await workspace.calls == 1)

        let written = try String(contentsOf: log.fileURL(for: F.pressedAt), encoding: .utf8)
        #expect(written == record.jsonLine(timeZone: F.paris) + "\n")
    }

    /// Quitting mid-capture: the utterance ends with its one line before `quit` returns, and a press after it starts
    /// nothing.
    @Test func quittingEndsTheUtteranceInFlightWithItsLine() async throws {
        let directory = try TemporaryDirectory()
        let (controller, log) = makeController(directory, workspace: await MainActorWorkspace(app: F.mail))
        var snapshots = controller.snapshots.makeAsyncIterator()

        await controller.triggerDown()
        _ = await next(&snapshots) { $0.utterance?.focus != nil }
        await controller.quit()

        #expect(await controller.phase == .idle)
        let written = try lines(log)
        #expect(written.count == 1)
        #expect(written.first?.contains(#""resolution":"discarded""#) == true)
        #expect(written.first?.contains(#""error":"cancelled""#) == true)
        await controller.triggerDown()
        #expect(await controller.phase == .idle)
        #expect(try lines(log).count == 1)
    }

    @Test func quittingWhileIdleWritesNothing() async throws {
        let directory = try TemporaryDirectory()
        let (controller, log) = makeController(directory, workspace: await MainActorWorkspace(app: F.mail))

        await controller.quit()
        await controller.triggerDown()
        await controller.triggerUp()

        #expect(await controller.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: log.fileURL(for: F.pressedAt).path(percentEncoded: false)))
    }

    @Test func pressWhileBusyWritesItsOwnLine() async throws {
        let directory = try TemporaryDirectory()
        let (controller, log) = makeController(directory, workspace: await MainActorWorkspace(app: F.mail))
        var snapshots = controller.snapshots.makeAsyncIterator()

        await controller.triggerDown()
        await controller.triggerDown()
        await controller.triggerUp()
        _ = await next(&snapshots) { $0.phase == .idle && $0.lastRecord?.resolution == .failed }

        let written = try String(contentsOf: log.fileURL(for: F.pressedAt), encoding: .utf8)
        let resolutions = written.split(separator: "\n").map { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["error"] as? String
        }
        #expect(resolutions == ["busy", "model_missing:small"])
    }
}
