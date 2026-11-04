import CoreGraphics
import Foundation
import HarkCore
import Testing

private typealias F = Fixture

/// Exact asks end to end through the controller, with the reader and the planner scripted: the read raced against its
/// timeout, the plan streamed as its understood line, the raster's lifetime, and what reaches the log.
@Suite(.timeLimit(.minutes(1)))
struct MathPipelineTests {
    static let sheet = MathFixtures.sheet(texts: ["4817.25", "1203.75", "Grand total"])
    static let understood = "You want the sum of both invoices."
    static let solved = planReply("SUM(C1,C2)", understood: understood)
    static let finished = LLMEvent.finished(Exact.summary(900))
    static let png = ImagePart(
        data: Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg==")
            ?? Data())

    static func raster(width: Int = 2) throws -> RegionRaster {
        let bitmap = try #require(
            CGContext(
                data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 4 * width,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return RegionRaster(image: try #require(bitmap.makeImage()))
    }

    struct Rig {
        let directory: TemporaryDirectory
        let pasteboard = FakePasteboard(text: nil)
        let planner: ScriptedPlanner
        let reader: ScriptedReader
        let asker: ScriptedAsker
        let log: UtteranceLog
        let controller: PipelineController

        init(
            planner: ScriptedPlanner = ScriptedPlanner([([solved], finished)]),
            reader: ScriptedReader = ScriptedReader(.success(sheet)),
            asker: ScriptedAsker = ScriptedAsker(
                pieces: ["About 6,000."], ending: .finished(Exact.summary(2_000, model: "free"))),
            words: Transcript = Exact.compute, readerTimeout: Duration = .seconds(60),
            solve: ExactRun.Solve? = nil
        ) throws {
            self.planner = planner
            self.reader = reader
            self.asker = asker
            directory = try TemporaryDirectory()
            log = UtteranceLog(directory: directory.url, timeZone: F.paris)
            let environment = PipelineEnvironment(
                workspace: SwitchableWorkspace(F.mail), pasteboard: pasteboard, clock: ManualWallClock(F.pressedAt),
                audio: ScriptedAudioInput(summary: F.speech), engine: FixedTranscriptionEngine(transcript: words),
                asker: asker, selection: NoTextFieldChecker(), planner: planner, reader: reader)
            var reducer = PipelineReducer()
            if let solve { reducer.solve = solve }
            controller = PipelineController(
                environment: environment, log: log, reducer: reducer, readerTimeout: readerTimeout)
        }

        func lines() throws -> [String] {
            try String(contentsOf: log.fileURL(for: F.pressedAt), encoding: .utf8).split(separator: "\n")
                .map(String.init)
        }
    }

    static func next(
        _ iterator: inout AsyncStream<PipelineSnapshot>.Iterator, where condition: (PipelineSnapshot) -> Bool
    ) async -> PipelineSnapshot? {
        while let snapshot = await iterator.next() {
            if condition(snapshot) { return snapshot }
        }
        return nil
    }

    /// The press with exact math on, a frame attached with its raster: the read starts while the key is held.
    static func start(
        _ rig: Rig, _ snapshots: inout AsyncStream<PipelineSnapshot>.Iterator, framed: Bool = true
    ) async throws -> UtteranceID {
        await rig.controller.setExactMath(true, locale: Locale(identifier: "en_US_POSIX"))
        await rig.controller.triggerDown(intent: Exact.assist)
        let id = try #require(await next(&snapshots) { $0.phase == .capturing }?.utterance?.id)
        if framed { await rig.controller.attachRegion(png, summary: F.region, for: id, raster: try raster()) }
        return id
    }

    static func stage(_ stage: AskStage) -> (PipelineSnapshot) -> Bool { { $0.ask?.stage == stage } }
    static let idle: @Sendable (PipelineSnapshot) -> Bool = { $0.phase == .idle && $0.lastRecord != nil }

    @Test func anExactAskStreamsItsUnderstoodLineThenPublishesTheComposedReply() async throws {
        let pieces = [
            #"{"understood": "You want the sum"#, #" of both invoices.", "formula": "SUM(C1,"#,
            #"C2)", "unit": "none"}"#,
        ]
        let rig = try Rig(planner: ScriptedPlanner([(pieces, Self.finished)], pace: .milliseconds(30)))
        let stream = rig.controller.askUpdates
        let collected = Task {
            var updates: [AskUpdate] = []
            for await update in stream {
                updates.append(update)
                if !update.text.isEmpty { break }
            }
            return updates
        }
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        let reviewing = try #require(await Self.next(&snapshots, where: Self.stage(.reviewing)))
        let updates = await collected.value
        let composed = try #require(reviewing.utterance?.reply)
        #expect(updates.last == AskUpdate(id: id, text: composed))
        #expect(updates.dropLast().allSatisfy { $0.text.isEmpty && !($0.planText ?? "").contains("formula") })
        #expect(updates.contains { $0.planText == Self.understood })
        // The array of understood lines streams beside the first (M14), which stays `planText`.
        #expect(updates.allSatisfy { $0.planTexts.isEmpty || $0.planText == $0.planTexts.first })
        let computation = try #require(reviewing.utterance?.math?.computation)
        #expect(computation.value == Decimal(string: "6021"))
        let answer = ExactAnswer(
            computation, sheet: Self.sheet, policy: .standard, fallback: Locale(identifier: "en_US_POSIX"))
        #expect(composed == answer.reply && composed.contains(Self.understood))
        #expect(rig.planner.requests.count == 1 && rig.asker.requests.isEmpty)
        #expect(rig.planner.requests[0].sheet == Self.sheet && rig.planner.requests[0].image == Self.png)
        #expect(rig.planner.requests[0].correction == nil)
        #expect(rig.reader.reads == 1)

        await rig.controller.copyAnswer("6021", for: id)
        let record = try #require(await Self.next(&snapshots, where: Self.idle)?.lastRecord)
        #expect(record.resolution == .textClipboard && record.actionType == .ask && record.error == nil)
        #expect(record.context == "region+cells" && record.llmModel == Exact.planModel && record.llmMs == 900)
        #expect(rig.pasteboard.text == "6021")
        #expect(try rig.lines().count == 1)
    }

    @Test func aRetrySendsTwoPlanRequestsTheSecondWithTheCorrection() async throws {
        let unknown = planReply("C99")
        let rig = try Rig(planner: ScriptedPlanner([([unknown], Self.finished), ([Self.solved], Self.finished)]))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.reviewing))
        #expect(
            rig.planner.requests.map(\.correction) == [
                nil, PlanCorrection(reply: unknown, note: PlanDefect.unknownCell.correction),
            ])
        #expect(rig.planner.requests.allSatisfy { $0.image == Self.png })
    }

    @Test func aSecondDefectLandsInMathFailed() async throws {
        let unknown = planReply("C99")
        let rig = try Rig(planner: ScriptedPlanner([([unknown], Self.finished)]))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.mathFailed(.plan(.unknownCell))))
        #expect(rig.planner.requests.count == 2)
        await rig.controller.cancel(id)
        let record = try #require(await Self.next(&snapshots, where: Self.idle)?.lastRecord)
        #expect(record.error == "plan_invalid:unknown_cell" && record.llmMs == 1_800)
    }

    @Test func aReaderThatNeverAnswersTimesOut() async throws {
        let rig = try Rig(reader: ScriptedReader(nil), readerTimeout: .milliseconds(50))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.mathFailed(.reader(.timeout))))
        await rig.controller.cancel(id)
        let record = try #require(await Self.next(&snapshots, where: Self.idle)?.lastRecord)
        #expect(record.error == "reader_failed:timeout")
        #expect(rig.planner.requests.isEmpty)
        #expect(await !rig.controller.holdsRaster)
    }

    @Test func aReadCancelledByTheChipsCrossSendsNothing() async throws {
        let rig = try Rig(reader: ScriptedReader(.success(Self.sheet), delay: .milliseconds(300)))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.removeRegion(for: id)
        #expect(await !rig.controller.holdsRaster)
        await rig.controller.finishCapture(id)
        let reviewing = try #require(await Self.next(&snapshots, where: Self.stage(.reviewing)))
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.reader.cancels == 1)
        #expect(reviewing.utterance?.math?.reading == .idle)
        #expect(rig.planner.requests.isEmpty && rig.asker.images == [nil])
    }

    // MARK: The raster

    @Test func theRasterLivesAsLongAsItsFrame() async throws {
        let rig = try Rig()
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        let second = try Self.raster(width: 3)
        await rig.controller.attachRegion(Self.png, summary: F.region, for: id, raster: second)
        #expect(await rig.controller.raster(for: id)?.image.width == 3)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.reviewing))
        #expect(await rig.controller.holdsRaster)
        #expect(await rig.controller.raster(for: id)?.image.width == 3)
        await rig.controller.cancel(id)
        _ = await Self.next(&snapshots, where: Self.idle)
        #expect(await !rig.controller.holdsRaster)
        #expect(await rig.controller.raster(for: id) == nil)
    }

    @Test func aRejectedFrameKeepsThePreviousRaster() async throws {
        let rig = try Rig()
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.reviewing))
        await rig.controller.attachRegion(Self.png, summary: F.region, for: id, raster: try Self.raster(width: 5))
        #expect(await rig.controller.raster(for: id)?.image.width == 2)
    }

    @Test func theChipsCrossFreesTheRaster() async throws {
        let rig = try Rig()
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        #expect(await rig.controller.holdsRaster)
        await rig.controller.removeRegion(for: id)
        #expect(await !rig.controller.holdsRaster)
    }

    @Test func anEmptyFollowUpThatFramedFreesItsRaster() async throws {
        let rig = try Rig()
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.reviewing))
        #expect(await rig.controller.followUpDown())
        let follow = try #require(await Self.next(&snapshots) { $0.phase == .capturing }?.utterance?.id)
        await rig.controller.attachRegion(Self.png, summary: F.region, for: follow, raster: try Self.raster(width: 4))
        #expect(await rig.controller.raster(for: follow) != nil)
        await rig.controller.cancel(follow)
        _ = await Self.next(&snapshots, where: Self.stage(.reviewing))
        #expect(await rig.controller.raster(for: follow) == nil)
        #expect(await rig.controller.raster(for: id) != nil)
    }

    // MARK: Decision 20

    @Test func theWayOutAfterAPlanDefectWritesItsReason() async throws {
        let rig = try Rig(solve: { _, _, _, _, _ in .failure(.plan(.unit("money and percent"))) })
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.mathFailed(.plan(.unit("money and percent")))))
        await rig.controller.retryWithoutExactMath(id)
        _ = await Self.next(&snapshots, where: Self.stage(.reviewing))
        #expect(rig.asker.images == [Self.png])
        await rig.controller.copyAnswer("About 6,000.", for: id)
        let record = try #require(await Self.next(&snapshots, where: Self.idle)?.lastRecord)
        #expect(record.error == "plan_invalid:unit" && record.resolution == .textClipboard)
        #expect(record.llmModel == "free" && record.llmMs == 2_000 && record.context == "region")
    }

    @Test func theWayOutAfterAReaderFailureWritesIt() async throws {
        let rig = try Rig(reader: ScriptedReader(.failure(.vision)))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.mathFailed(.reader(.vision))))
        await rig.controller.retryWithoutExactMath(id)
        _ = await Self.next(&snapshots, where: Self.stage(.reviewing))
        await rig.controller.copyAnswer("About 6,000.", for: id)
        #expect(try #require(await Self.next(&snapshots, where: Self.idle)?.lastRecord).error == "reader_failed:vision")
    }

    @Test func theWayOutChosenWhileReadingWritesNull() async throws {
        let rig = try Rig(reader: ScriptedReader(nil))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.reading))
        await rig.controller.retryWithoutExactMath(id)
        _ = await Self.next(&snapshots, where: Self.stage(.reviewing))
        await rig.controller.copyAnswer("About 6,000.", for: id)
        let record = try #require(await Self.next(&snapshots, where: Self.idle)?.lastRecord)
        #expect(record.error == nil && record.context == "region")
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.reader.cancels == 1)
    }

    @Test func aCancelAfterTheWayOutKeepsCancelled() async throws {
        let rig = try Rig(reader: ScriptedReader(.failure(.vision)))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.mathFailed(.reader(.vision))))
        await rig.controller.retryWithoutExactMath(id)
        _ = await Self.next(&snapshots, where: Self.stage(.reviewing))
        await rig.controller.cancel(id)
        #expect(try #require(await Self.next(&snapshots, where: Self.idle)?.lastRecord).error == "cancelled")
    }

    @Test func noTextFieldWinsOverThePlanDefect() async throws {
        let rig = try Rig(solve: { _, _, _, _, _ in .failure(.plan(.unit("x"))) })
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.mathFailed(.plan(.unit("x")))))
        await rig.controller.retryWithoutExactMath(id)
        _ = await Self.next(&snapshots, where: Self.stage(.reviewing))
        await rig.controller.replaceSelection(with: "About 6,000.", for: id)
        let record = try #require(await Self.next(&snapshots, where: Self.idle)?.lastRecord)
        #expect(record.resolution == .textClipboard && record.error == "no_text_field")
    }

    // MARK: Quit

    @Test func quitWhileReadingCancelsTheRead() async throws {
        let rig = try Rig(reader: ScriptedReader(nil))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.reading))
        await rig.controller.quit()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.reader.cancels == 1)
        let lines = try rig.lines()
        #expect(lines.count == 1 && lines[0].contains(#""error":"cancelled""#))
        #expect(await !rig.controller.holdsRaster)
    }

    @Test func quitWhilePlanningClosesTheStream() async throws {
        let rig = try Rig(planner: ScriptedPlanner([(["{"], nil)]))
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.planning))
        await rig.controller.quit()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.planner.closedByConsumer == 1)
        let lines = try rig.lines()
        #expect(lines.count == 1 && lines[0].contains(#""context":"region+cells""#))
    }

    // MARK: Never written

    @Test func aTwoTurnExactConversationWritesNoCellNoPlanAndNoResult() async throws {
        let rig = try Rig()
        var snapshots = rig.controller.snapshots.makeAsyncIterator()
        let id = try await Self.start(rig, &snapshots)
        await rig.controller.finishCapture(id)
        _ = await Self.next(&snapshots, where: Self.stage(.reviewing))
        #expect(await rig.controller.followUpDown())
        let follow = try #require(await Self.next(&snapshots) { $0.phase == .capturing }?.utterance?.id)
        await rig.controller.finishCapture(follow)
        let reviewing = try #require(await Self.next(&snapshots, where: Self.stage(.reviewing)))
        #expect(reviewing.utterance?.id == follow)
        // Turn 1's frame goes once, with turn 1 in the history: the follow-up framed nothing of its own.
        #expect(rig.planner.requests.count == 2 && rig.planner.requests[1].image == nil)
        #expect(rig.planner.requests[1].frames[id] == Self.png)
        #expect(rig.planner.requests[1].thread?.turns.first?.formula == "SUM(C1,C2)")
        await rig.controller.copyAnswer("6021", for: follow)
        _ = await Self.next(&snapshots, where: Self.idle)
        let lines = try rig.lines()
        #expect(lines.count == 2)
        let needles = [
            "4817", "1203", "Grand total", "understood", Self.understood, "SUM(", "C1", "6021", "6,021", "%%",
            "iVBOR",
        ]
        for line in lines {
            for needle in needles { #expect(!line.contains(needle), "\(needle)") }
        }
        #expect(lines[0].contains(#""error":"followed_up""#) && lines[0].hasSuffix(#""context":"region+cells"}"#))
        #expect(lines[1].hasSuffix(#""context":"region+cells+history"}"#))
    }
}
