import AppKit
import Foundation
import HarkCore
import Observation
import os

/// What the Ask panel shows, fed by the pipeline's snapshots and its stream of answer text. The state is
/// `AskPresentation`'s; this keeps the text, opens and closes the panel, and sends the buttons to the controller.
///
/// Every close brings the caller back, whatever ended the ask: a Services call left Hark in front.
/// Why framing a region cannot work during an ask.
enum FramingBlock: Equatable {
    /// Hark has no Screen Recording grant yet.
    case noScreenRecording
    /// The active model is known not to read images.
    case modelCannotSee
    /// The conversation holds as many frames as it may (M12): a follow-up goes on with words.
    case framesFull
}

@Observable
final class AskPanelModel {
    private(set) var state = AskPanelState.closed
    /// The spoken instruction, once transcribed.
    private(set) var instruction: String?
    /// The selection's opening words; empty for the assistant, which has none.
    private(set) var quote = ""
    /// Replace, Insert, or Copy alone, from the utterance's intent and the focus at the press.
    private(set) var apply = AskApply.replace
    /// The selection is longer than the cap and only its start is sent.
    private(set) var truncated = false
    private(set) var maxSelectionChars = LLMConfig.defaultMaxSelectionChars
    /// The answer as it streams. On review it is copied into `answer`, which the user edits.
    private(set) var streamed = ""
    var answer = ""
    /// `127.0.0.1:8002`: the server "Thinking…" names after a moment.
    private(set) var server = ""
    /// The host of a server off this Mac, shown for as long as the panel is open; nil for a server on this Mac.
    private(set) var remoteHost: String?
    /// 60% of the screen the panel opened on; a longer answer scrolls.
    var maxAnswerHeight: CGFloat = 480
    /// What the pre-flight found wrong with the server, shown while the user is still speaking.
    private(set) var preflightFailure: LLMFailure?
    /// Each framed turn's thumbnail, made in memory from its captured image, kept while the state names the turn.
    private(set) var regionThumbnails: [UtteranceID: CGImage] = [:]
    /// The live turn's framed region, in pixels, as it goes to the model.
    private(set) var regionPixelSize: CGSize?
    /// The conversation's earlier turns, oldest first: none for a single ask.
    private(set) var turns: [AskTurnRow] = []
    /// Turn 1 of the conversation on show: the reset keys on it, and its chips stay fixed after it.
    private(set) var threadRoot: UtteranceID?
    /// The footer's line in review: how to follow up, or that the conversation is full.
    private(set) var footerHint: AskFooterHint?
    /// A talk key was pressed while the panel shows: for `AskPresentation.busyNudgeFor`, the panel says how to dictate.
    private(set) var showsBusyNudge = false
    /// Ask without the image is offered only when this turn's frame is the conversation's only one.
    private(set) var offersAskWithoutImage = false
    /// An image ask's restatement of what the user is after: the reply's `%%` line, apart from the answer.
    private(set) var intent: String?
    /// ⌃⌥ are held during the ask's capture: the overlay takes the mouse and the panel steps back.
    private(set) var isFraming = false
    /// Framing cannot work during this ask, and why: the dot shows a slash and the panel says so.
    private(set) var framingBlocked: FramingBlock?
    /// Whether the active model reads images, from the models list or what an ask learned; nil when unknown.
    private(set) var visionVerdict: Bool?
    /// Replace is offered: never after an ask that carried a region, which has no text to replace.
    private(set) var allowsReplace = true
    /// The request on its way carried the frame: the wait reads it, and the reply starts with its restatement.
    private(set) var sentFrame = false
    /// Allow… was pressed for Screen Recording: macOS reads the grant at launch, so the panel offers Reopen Hark.
    private(set) var screenRecordingRequested = false
    /// Set by `AppModel`: `GET /models` on the active profile, run when an ask opens.
    @ObservationIgnored var preflight: (() async -> LLMProbeResult?)?
    /// Set by `AppModel`: Settings › Ask, for Choose another model…
    @ObservationIgnored var openAskSettings: (() -> Void)?
    /// Set by `AppModel`: the system's Screen Recording alert once, then System Settings.
    @ObservationIgnored var requestScreenRecording: (() -> Void)?
    /// Set by `AppModel`: quits and opens Hark again, so macOS reads the new grant.
    @ObservationIgnored var relaunch: (() -> Void)?
    /// Set by `RegionFraming`: Esc while a drag is under way drops the drag, not the ask. True when it did.
    @ObservationIgnored var dropDrag: (() -> Bool)?
    /// The reply as it streams, restatement included. An image ask shows its answer in `streamed`, its restatement in
    /// `intent`.
    @ObservationIgnored private var reply = ""
    /// The answer as the reply gave it when review began, so text that lands after can follow until the user edits.
    @ObservationIgnored private var reviewedReply = ""
    /// The turn a follow-up parked, as the panel left it: Esc during the follow-up's capture brings it back, edits
    /// included.
    @ObservationIgnored private var parkedTurn: (id: UtteranceID, turn: TurnText)?
    @ObservationIgnored private var nudge: Task<Void, Never>?

    @ObservationIgnored private let controller: PipelineController
    @ObservationIgnored private let workspace: AppKitWorkspace
    @ObservationIgnored private let pasteboard: AppKitPasteboard
    @ObservationIgnored private lazy var panel: AskPanel = {
        let panel = AskPanel(model: self)
        panel.onUserMove = { [weak self] topLeft in self?.remember(topLeft) }
        return panel
    }()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var snapshot = PipelineSnapshot(phase: .idle)
    /// The live turn of the ask on show, and the app it came from.
    @ObservationIgnored private var id: UtteranceID?
    @ObservationIgnored private var caller: AppIdentity?
    /// `-HarkDebugPreview ask…`: a fixed state that snapshots do not move.
    @ObservationIgnored private var pinned = false
    /// `-HarkDebugPreview ask…`: the turn a pin shows live, since a preview has no utterance.
    @ObservationIgnored private var previewLive: UtteranceID?
    /// `-HarkDebugPreview ask-remote`: the sample host stays when commands.yaml loads after the pin.
    @ObservationIgnored private var pinnedRemote = false

    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "ask")
    /// As long as the panel's Paste waits for an app that is slow to come forward.
    private static let activationTimeout = Duration.seconds(2)

    init(
        controller: PipelineController, workspace: AppKitWorkspace, pasteboard: AppKitPasteboard,
        defaults: UserDefaults
    ) {
        self.controller = controller
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.defaults = defaults
    }

    /// Where the user last dragged the panel: its top-left corner, in screen points. Unset, the top right of the screen.
    private static let positionKey = "HarkAskPanelTopLeft"

    private var rememberedTopLeft: NSPoint? {
        guard let pair = defaults.array(forKey: Self.positionKey) as? [Double], pair.count == 2 else { return nil }
        return NSPoint(x: pair[0], y: pair[1])
    }

    /// A preview is a second process on the same defaults: its drags must not move the real panel's spot.
    private func remember(_ topLeft: NSPoint) {
        Self.logger.info(
            "ask panel moved to \(Int(topLeft.x), privacy: .public), \(Int(topLeft.y), privacy: .public)\(self.pinned ? " (preview, not kept)" : "", privacy: .public)"
        )
        guard !pinned else { return }
        defaults.set([Double(topLeft.x), Double(topLeft.y)], forKey: Self.positionKey)
    }

    /// The active profile's address and the selection cap, from commands.yaml.
    func configure(_ llm: LLMConfig) {
        server = llm.activeProfile?.endpoint ?? ""
        if !pinnedRemote { remoteHost = llm.activeProfile?.remoteHost }
        maxSelectionChars = llm.maxSelectionChars
    }

    func update(_ snapshot: PipelineSnapshot) {
        guard !pinned else { return }
        self.snapshot = snapshot
        if let utterance = snapshot.utterance, utterance.intent.isAsk, utterance.id != id {
            let root = AskPresentation.threadRoot(utterance)
            if root != threadRoot {
                begin(utterance, root: root)
            } else {
                turn(to: utterance)
            }
        }
        if let utterance = snapshot.utterance, utterance.id == id {
            // The assistant's focus arrives with the probe, after the press.
            apply = AskPresentation.apply(utterance)
            allowsReplace = AskPresentation.allowsReplace(utterance)
            offersAskWithoutImage = AskPresentation.offersAskWithoutImage(utterance)
            sentFrame = isImageAsk
            turns = AskPresentation.earlierTurns(utterance)
            // The controller's rule for the pixels: a turn's thumbnail goes when the state no longer names it with a
            // frame (the chip's ×, an ask without the image, a follow-up dropped by Esc), and turn 1's stays.
            let framed = AskPresentation.framedTurns(utterance)
            regionThumbnails = regionThumbnails.filter { framed.contains($0.key) }
            regionPixelSize = utterance.region.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
        }
        refresh()
    }

    /// A new conversation: everything from the last one goes.
    private func begin(_ utterance: UtteranceContext, root: UtteranceID) {
        id = utterance.id
        threadRoot = root
        caller = utterance.intent.caller
        let selection = utterance.intent.selection?.text ?? ""
        quote = AskPresentation.quote(selection)
        truncated = selection.count > maxSelectionChars
        regionThumbnails = [:]
        turns = []
        parkedTurn = nil
        preflightFailure = nil
        screenRecordingRequested = false
        resetTurn()
        check(utterance.id)
    }

    /// The next turn of the same conversation, or the parked one again after Esc: the earlier turns, the chips of turn
    /// 1 and the thumbnails stay.
    private func turn(to utterance: UtteranceContext) {
        if let id, utterance.parked?.context.id == id {
            parkedTurn = (id, turnText)
        }
        id = utterance.id
        if let parked = parkedTurn, parked.id == utterance.id {
            parkedTurn = nil
            restore(parked.turn)
        } else {
            resetTurn()
        }
    }

    private var turnText: TurnText {
        TurnText(
            instruction: instruction, reply: reply, reviewedReply: reviewedReply, streamed: streamed, answer: answer,
            intent: intent)
    }

    private func restore(_ turn: TurnText) {
        resetTurn()
        instruction = turn.instruction
        reply = turn.reply
        reviewedReply = turn.reviewedReply
        streamed = turn.streamed
        answer = turn.answer
        intent = turn.intent
    }

    private func resetTurn() {
        instruction = nil
        reply = ""
        reviewedReply = ""
        streamed = ""
        answer = ""
        intent = nil
        regionPixelSize = nil
        footerHint = nil
        isFraming = false
        framingBlocked = visionVerdict == false ? .modelCannotSee : nil
    }

    /// The live turn, or the one a preview pins.
    private var liveID: UtteranceID? { id ?? (pinned ? previewLive : nil) }

    /// The live turn's thumbnail.
    var regionThumbnail: CGImage? { liveID.flatMap { regionThumbnails[$0] } }

    /// The live turn is a follow-up: turn 1's chips are fixed above it.
    var isFollowUp: Bool { threadRoot != nil && liveID != threadRoot }

    /// Turn 1's frame while a follow-up is live: its thumbnail and size, for the fixed chip.
    var rootFrame: (thumbnail: CGImage?, size: CGSize)? {
        guard isFollowUp, let root = threadRoot, let region = turns.first(where: { $0.id == root })?.region else {
            return nil
        }
        return (regionThumbnails[root], CGSize(width: region.pixelWidth, height: region.pixelHeight))
    }

    /// A press the pipeline turned away as busy while the panel shows: say how to dictate, for two seconds.
    func showBusyNudge() {
        guard !pinned, AskPresentation.showsBusyNudge(state) else { return }
        nudge?.cancel()
        showsBusyNudge = true
        nudge = Task { [weak self] in
            try? await Task.sleep(for: AskPresentation.busyNudgeFor)
            guard !Task.isCancelled else { return }
            self?.showsBusyNudge = false
        }
    }

    func update(_ update: AskUpdate) {
        guard !pinned, update.id == id else { return }
        reply = update.text
        let complete = state == .reviewing
        if isImageAsk {
            let split = IntentSplit.split(reply, complete: complete)
            intent = split.intent
            streamed = split.answer
        } else {
            streamed = reply
        }
        // The answer's end and the pipeline's "finished" come on two streams, and the second may land first: text that
        // arrives once review has begun still reaches the editable answer, unless the user has edited it.
        if complete, answer == reviewedReply {
            answer = streamed
            reviewedReply = streamed
        }
        refresh()
    }

    /// The request on its way carried a frame, this turn's or an earlier one's: its reply starts with the `%%`
    /// restatement.
    private var isImageAsk: Bool {
        guard let utterance = snapshot.utterance, utterance.id == id else { return false }
        return AskPresentation.expectsRestatement(utterance)
    }

    // MARK: - Framing, fed by `RegionFraming` and `AppModel`

    /// ⌃⌥ are held: the panel steps back and lets the mouse through to the overlay.
    func setFraming(_ framing: Bool) {
        guard !pinned else { return }
        isFraming = framing
        panel.ignoresMouseEvents = framing
    }

    func setFramingBlocked(_ block: FramingBlock?) {
        guard !pinned else { return }
        framingBlocked = block
    }

    /// The captured region's thumbnail, for the ask on show only.
    func showRegion(thumbnail: CGImage?, for ask: UtteranceID) {
        guard !pinned, ask == id else { return }
        regionThumbnails[ask] = thumbnail
    }

    /// What the models list or an ask taught about the active model. A model known to be blind blocks framing at
    /// once; a verdict that changes back lifts that block.
    func setVisionVerdict(_ verdict: Bool?) {
        guard !pinned else { return }
        visionVerdict = verdict
        if verdict == false, framingBlocked == nil {
            framingBlocked = .modelCannotSee
        } else if verdict != false, framingBlocked == .modelCannotSee {
            framingBlocked = nil
        }
    }

    private func refresh() {
        let current = snapshot.utterance?.id == id ? snapshot : PipelineSnapshot(phase: .idle)
        var next = AskPresentation.state(current, streamed: !streamed.isEmpty)
        // A Retry starts from nothing: the failed call's words are not the new answer.
        if case .failed = state, next == .streaming {
            reply = ""
            streamed = ""
            intent = nil
            next = .thinking
        }
        if let heard = current.ask?.instruction { instruction = heard }
        footerHint = AskPresentation.footerHint(current)
        if next == .reviewing, state != .reviewing {
            if isImageAsk {
                let split = IntentSplit.split(reply, complete: true)
                intent = split.intent
                streamed = split.answer
            }
            // A turn brought back by Esc keeps the answer as the user left it.
            if answer == reviewedReply { answer = streamed }
            reviewedReply = streamed
        }
        guard next != state else { return }
        let wasOpen = state != .closed
        state = next
        if next == .closed, wasOpen {
            close()
        } else if !wasOpen {
            panel.open(at: rememberedTopLeft)
        }
    }

    private func check(_ ask: UtteranceID) {
        guard let preflight else { return }
        Task {
            guard case .failed(let failure)? = await preflight(), id == ask else { return }
            preflightFailure = failure
        }
    }

    /// Hides the panel, then brings the caller back, as the panel's Paste does.
    private func close() {
        panel.dismiss()
        id = nil
        threadRoot = nil
        turns = []
        regionThumbnails = [:]
        parkedTurn = nil
        footerHint = nil
        nudge?.cancel()
        showsBusyNudge = false
        guard let caller else { return }
        self.caller = nil
        Task { [workspace] in
            guard await workspace.activateAndWait(caller, timeout: Self.activationTimeout) else {
                Self.logger.error("\(caller.logName, privacy: .public) did not come back after the ask")
                return
            }
        }
    }

    // MARK: - The buttons

    func done() {
        guard let id else { return }
        Task { [controller] in await controller.finishCapture(id) }
    }

    func cancel() {
        guard !pinned else { return closePreview() }
        guard let id else { return }
        Task { [controller] in await controller.cancel(id) }
    }

    func retry() {
        guard let id else { return }
        Task { [controller] in await controller.retryAsk(id) }
    }

    /// The region chip's ×: the ask goes on without the frame.
    func removeRegion() {
        guard let id else { return }
        Task { [controller] in await controller.removeRegion(for: id) }
    }

    /// Ask without the image, after a failure: the same instruction, sent again without the frame.
    func askWithoutRegion() {
        guard let id else { return }
        Task { [controller] in await controller.retryAskWithoutRegion(id) }
    }

    /// Choose another model…: Settings › Ask.
    func chooseAnotherModel() {
        openAskSettings?()
    }

    /// Allow… for Screen Recording.
    func allowScreenRecording() {
        screenRecordingRequested = true
        requestScreenRecording?()
    }

    /// Reopen Hark, once Screen Recording is granted.
    func reopenForScreenRecording() {
        relaunch?()
    }

    func copy() {
        guard let id else { return }
        let text = answer
        Task { [controller] in await controller.copyAnswer(text, for: id) }
    }

    /// The panel closes and the caller comes back; the pipeline checks the selection, then writes the answer over it.
    /// Insert is the same path: the check expects nothing selected, and the answer goes in at the caret.
    func replace() {
        guard let id else { return }
        let text = answer
        Task { [controller] in await controller.replaceSelection(with: text, for: id) }
    }

    /// After a failure, the instruction is what the user may want to keep: it goes on the clipboard, and the ask ends
    /// with its failure.
    func copyInstruction() {
        guard let id, let instruction else { return }
        Task { [controller, pasteboard] in
            _ = await pasteboard.writeText(instruction)
            await controller.cancel(id)
        }
    }
}

extension AskPanelModel {
    /// `-HarkDebugPreview ask`, `ask-listening`, `ask-thinking`, `ask-streaming` or `ask-error`, plus `ask-remote`: the
    /// panel pinned in one state with sample text in the preview's language, for screenshots. Esc closes it.
    /// `assistant`, `assistant-nofield` and `assistant-listening` are the Ask key with nothing selected. Visual
    /// Context: `ask-region` (listening with a framed region), `ask-intent` (an image ask's answer under its
    /// restatement), `ask-novision`, `ask-novision-mtp` (a model that cannot read the image) and `ask-permission`
    /// (framing blocked by Screen Recording). A conversation (M12): `ask-thread` (three turns on a selection),
    /// `ask-thread-framed` (turn 1 framed, turn 2 in words, turn 3 a second frame), `ask-thread-listening` (turn 2
    /// listening with its own frame) and `ask-thread-full` (six turns).
    func showPreview(_ names: Set<String>) {
        let french = Locale.preferredLanguages.first?.hasPrefix("fr") == true
        let assistant = names.contains { $0.hasPrefix("assistant") }
        if showRegionPreview(names, french: french) || showThreadPreview(names, french: french) { return }
        let pinnedState: AskPanelState? =
            if names.contains("ask-listening") || names.contains("assistant-listening") {
                .listening
            } else if names.contains("ask-thinking") {
                .thinking
            } else if names.contains("ask-streaming") {
                .streaming
            } else if names.contains("ask-error") {
                .failed(.notRunning(endpoint: "127.0.0.1:8002"))
            } else if names.contains("ask") || names.contains("assistant") || names.contains("assistant-nofield") {
                .reviewing
            } else {
                nil
            }
        guard let pinnedState else { return }
        pinned = true
        let sample = AskPreviewSample(french: french, assistant: assistant)
        quote = assistant ? "" : AskPresentation.quote(sample.selection)
        apply = !assistant ? .replace : names.contains("assistant-nofield") ? .copyOnly : .insert
        instruction = pinnedState == .listening ? nil : sample.instruction
        streamed = pinnedState == .streaming ? String(sample.answer.prefix(70)) : sample.answer
        answer = sample.answer
        if server.isEmpty { server = "127.0.0.1:8002" }
        // `ask-remote` adds the line a cloud profile shows, with a sample host.
        if names.contains("ask-remote") {
            pinnedRemote = true
            remoteHost = "api.example.com"
        }
        state = pinnedState
        panel.open(at: rememberedTopLeft)
    }

    private func closePreview() {
        panel.dismiss()
        state = .closed
    }

    /// The Visual Context pins: an ask about the invoices of the M11 plan, framed rather than selected.
    private func showRegionPreview(_ names: Set<String>, french: Bool) -> Bool {
        let model = "mtplx-bonsai-2-27b-optimized-speed"
        let pinnedState: AskPanelState
        if names.contains("ask-region") || names.contains("ask-permission") {
            pinnedState = .listening
        } else if names.contains("ask-intent") {
            pinnedState = .reviewing
        } else if names.contains("ask-novision") {
            pinnedState = .failed(.noVision(model: model, reason: .noVision))
        } else if names.contains("ask-novision-mtp") {
            pinnedState = .failed(.noVision(model: model, reason: .needsMTPMode))
        } else {
            return false
        }
        pinned = true
        let sample = RegionPreviewSample(french: french)
        quote = ""
        apply = .insert
        allowsReplace = false
        instruction = pinnedState == .listening ? nil : sample.instruction
        if names.contains("ask-permission") {
            framingBlocked = .noScreenRecording
        } else {
            previewLive = UtteranceID(1)
            regionThumbnails[UtteranceID(1)] = RegionPreviewSample.thumbnail()
            offersAskWithoutImage = true
            regionPixelSize = CGSize(width: 1400, height: 1200)
            visionVerdict = !names.contains { $0.hasPrefix("ask-novision") }
        }
        if pinnedState == .reviewing {
            intent = sample.intent
            streamed = sample.answer
            answer = sample.answer
        }
        if server.isEmpty { server = "127.0.0.1:8002" }
        state = pinnedState
        panel.open(at: rememberedTopLeft)
        return true
    }
}

extension AskPanelModel {
    /// The conversation pins: sample turns in the preview's language, the live one last.
    fileprivate func showThreadPreview(_ names: Set<String>, french: Bool) -> Bool {
        let framed = names.contains("ask-thread-framed")
        let listening = names.contains("ask-thread-listening")
        let full = names.contains("ask-thread-full")
        guard framed || listening || full || names.contains("ask-thread") else { return false }
        pinned = true
        let sample = ThreadPreviewSample(french: french, framed: framed || listening)
        let region = RegionSummary(
            rect: CGRect(x: 120, y: 80, width: 700, height: 600), pixelWidth: 1400, pixelHeight: 1200, bytes: 412_000,
            displayID: 1)
        let earlier = listening ? 1 : full ? 5 : 2
        turns = (0..<earlier).map { index in
            let words = sample.turns[index % sample.turns.count]
            let ownFrame = (framed || listening) && index == 0
            return AskTurnRow(
                id: UtteranceID(UInt64(index + 1)), instruction: words.instruction, restatement: words.restatement,
                answer: words.answer, region: ownFrame ? region : nil)
        }
        threadRoot = UtteranceID(1)
        let live = UtteranceID(UInt64(earlier + 1))
        previewLive = live
        if framed || listening {
            regionThumbnails[UtteranceID(1)] = RegionPreviewSample.thumbnail()
            regionThumbnails[live] = RegionPreviewSample.thumbnail()
            regionPixelSize = CGSize(width: 1200, height: 800)
            visionVerdict = true
        }
        quote = framed || listening ? "" : AskPresentation.quote(sample.selection)
        apply = framed || listening ? .insert : .replace
        allowsReplace = !(framed || listening)
        let last = sample.turns[earlier % sample.turns.count]
        instruction = listening ? nil : last.instruction
        intent = framed ? last.restatement : nil
        streamed = last.answer
        answer = last.answer
        footerHint = full ? .full : .followUp(turn: earlier + 1, of: AskThread.maxTurns)
        if server.isEmpty { server = "127.0.0.1:8002" }
        state = listening ? .listening : .reviewing
        panel.open(at: rememberedTopLeft)
        return true
    }
}

/// The conversation preview's sample: sample text, not catalog strings.
private struct ThreadPreviewSample {
    struct Turn {
        let instruction: String
        let restatement: String?
        let answer: String
    }

    let selection: String
    let turns: [Turn]

    init(french: Bool, framed: Bool) {
        selection =
            french
            ? "Bonjour à tous, nous avons validé le budget du troisième trimestre et décalé le lancement au 14 octobre."
            : "Hi all, we approved the Q3 budget and moved the launch to October 14."
        let restate = { (text: String) in framed ? text : nil }
        turns =
            french
            ? [
                Turn(
                    instruction: "Mets-le en liste à puces.", restatement: restate("Tu veux les décisions en liste."),
                    answer: "- Budget du troisième trimestre validé\n- Lancement décalé au 14 octobre"),
                Turn(
                    instruction: "Ajoute qui s’en occupe.", restatement: restate("Tu veux un responsable par point."),
                    answer: "- Budget validé (Marc)\n- Lancement au 14 octobre (Claire)"),
                Turn(
                    instruction: "Plus court.", restatement: restate("Tu veux la même liste, plus brève."),
                    answer: "- Budget\u{00A0}: Marc\n- Lancement 14/10\u{00A0}: Claire"),
            ]
            : [
                Turn(
                    instruction: "Turn it into a bulleted list.",
                    restatement: restate("You want the decisions listed."),
                    answer: "- Q3 budget approved\n- Launch moved to October 14"),
                Turn(
                    instruction: "Add who owns each one.", restatement: restate("You want an owner per item."),
                    answer: "- Budget approved (Marc)\n- Launch on October 14 (Claire)"),
                Turn(
                    instruction: "Shorter.", restatement: restate("You want the same list, briefer."),
                    answer: "- Budget: Marc\n- Launch 10/14: Claire"),
            ]
    }
}

/// A turn's words as the panel showed them, kept while a follow-up is captured.
private struct TurnText {
    let instruction: String?
    let reply: String
    let reviewedReply: String
    let streamed: String
    let answer: String
    let intent: String?
}

/// The Visual Context preview's sample: the invoices of the M11 plan, sample text, not catalog strings.
private struct RegionPreviewSample {
    let instruction: String
    let intent: String
    let answer: String

    init(french: Bool) {
        if french {
            instruction = "Additionne toutes les factures de cette année, combien j'ai vraiment payé ?"
            intent = "Tu veux le net payé en 2026 : factures moins avoirs, la facture de janvier remboursée exclue."
            answer =
                "802,42 € payés en 2026.\n\n- Factures payées : 1 072,66 €\n- Avoirs : −270,24 €\n"
                + "- Facture du 6 janvier (108,90 €) remboursée, non comptée"
        } else {
            instruction = "Add up all of this year's invoices: how much did I really pay?"
            intent = "You want the net paid in 2026: invoices minus credits, the refunded January invoice left out."
            answer =
                "€802.42 paid in 2026.\n\n- Paid invoices: €1,072.66\n- Credits: −€270.24\n"
                + "- The January 6 invoice (€108.90) was refunded and is not counted"
        }
    }

    /// A table drawn in code: white rows and grey rules, at the chip's aspect.
    static func thumbnail() -> CGImage? {
        let width = 280
        let height = 240
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.82, alpha: 1))
        for row in stride(from: 16, to: height, by: 18) {
            context.fill(CGRect(x: 12, y: row, width: width - 24, height: 1))
        }
        context.setFillColor(CGColor(gray: 0.35, alpha: 1))
        for row in stride(from: 22, to: height - 18, by: 18) {
            context.fill(CGRect(x: 14, y: row, width: 54, height: 6))
            context.fill(CGRect(x: 150, y: row, width: 40, height: 6))
        }
        return context.makeImage()
    }
}

/// The preview's sample: sample text, not catalog strings.
private struct AskPreviewSample {
    let selection: String
    let instruction: String
    let answer: String

    init(french: Bool, assistant: Bool) {
        if assistant {
            selection = ""
            instruction =
                french
                ? "Écris un mail pour décliner la réunion de jeudi." : "Write an email to decline Thursday's meeting."
            answer =
                french
                ? "Bonjour à tous,\n\nJe ne pourrai malheureusement pas assister à la réunion de jeudi. Pouvez-vous me "
                    + "transmettre le compte rendu ?\n\nMerci, et bonne journée."
                : "Hi all,\n\nUnfortunately I won't be able to attend Thursday's meeting. Could you send me the notes "
                    + "afterwards?\n\nThanks, and have a good day."
        } else if french {
            selection =
                "Bonjour à tous, je voulais revenir sur la réunion de ce matin. Nous avons validé le budget du troisième "
                + "trimestre, décidé de décaler le lancement au 14 octobre, et Claire prend en charge la communication."
            instruction = "Mets-le en liste à puces."
            answer =
                "- Budget du troisième trimestre validé\n- Lancement décalé au 14 octobre\n- Claire prend en charge la "
                + "communication"
        } else {
            selection =
                "Hi all, a quick follow-up on this morning's meeting. We approved the Q3 budget, agreed to move the "
                + "launch to October 14, and Claire is taking over communications."
            instruction = "Turn it into a bulleted list."
            answer = "- Q3 budget approved\n- Launch moved to October 14\n- Claire takes over communications"
        }
    }
}
