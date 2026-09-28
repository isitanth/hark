import AppKit
import Foundation
import HarkCore
import Observation
import os

/// What the Ask panel shows, fed by the pipeline's snapshots and its stream of answer text. The state is
/// `AskPresentation`'s; this keeps the text, opens and closes the panel, and sends the buttons to the controller.
///
/// Every close brings the caller back, whatever ended the ask: a Services call left Hark in front.
@Observable
final class AskPanelModel {
    private(set) var state = AskPanelState.closed
    /// The spoken instruction, once transcribed.
    private(set) var instruction: String?
    private(set) var quote = ""
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
    /// Set by `AppModel`: `GET /models` on the active profile, run when an ask opens.
    @ObservationIgnored var preflight: (() async -> LLMProbeResult?)?

    @ObservationIgnored private let controller: PipelineController
    @ObservationIgnored private let workspace: AppKitWorkspace
    @ObservationIgnored private let pasteboard: AppKitPasteboard
    @ObservationIgnored private lazy var panel = AskPanel(model: self)
    @ObservationIgnored private var snapshot = PipelineSnapshot(phase: .idle)
    /// The ask on show and the app it came from.
    @ObservationIgnored private var id: UtteranceID?
    @ObservationIgnored private var caller: AppIdentity?
    /// `-HarkDebugPreview ask…`: a fixed state that snapshots do not move.
    @ObservationIgnored private var pinned = false

    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "ask")
    /// As long as the panel's Paste waits for an app that is slow to come forward.
    private static let activationTimeout = Duration.seconds(2)

    init(controller: PipelineController, workspace: AppKitWorkspace, pasteboard: AppKitPasteboard) {
        self.controller = controller
        self.workspace = workspace
        self.pasteboard = pasteboard
    }

    /// The active profile's address and the selection cap, from commands.yaml.
    func configure(_ llm: LLMConfig) {
        server = llm.activeProfile?.endpoint ?? ""
        remoteHost = llm.activeProfile?.remoteHost
        maxSelectionChars = llm.maxSelectionChars
    }

    func update(_ snapshot: PipelineSnapshot) {
        guard !pinned else { return }
        self.snapshot = snapshot
        if case .ask(let selection)? = snapshot.utterance?.intent, let next = snapshot.utterance?.id, next != id {
            id = next
            caller = selection.caller
            quote = AskPresentation.quote(selection.text)
            truncated = selection.text.count > maxSelectionChars
            instruction = nil
            streamed = ""
            answer = ""
            preflightFailure = nil
            check(next)
        }
        refresh()
    }

    func update(_ update: AskUpdate) {
        guard !pinned, update.id == id else { return }
        streamed = update.text
        refresh()
    }

    private func refresh() {
        let current = snapshot.utterance?.id == id ? snapshot : PipelineSnapshot(phase: .idle)
        var next = AskPresentation.state(current, streamed: !streamed.isEmpty)
        // A Retry starts from nothing: the failed call's words are not the new answer.
        if case .failed = state, next == .streaming {
            streamed = ""
            next = .thinking
        }
        if let heard = current.ask?.instruction { instruction = heard }
        if next == .reviewing, state != .reviewing { answer = streamed }
        guard next != state else { return }
        let wasOpen = state != .closed
        state = next
        if next == .closed, wasOpen {
            close()
        } else if !wasOpen {
            panel.open()
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

    func copy() {
        guard let id else { return }
        let text = answer
        Task { [controller] in await controller.copyAnswer(text, for: id) }
    }

    /// The panel closes and the caller comes back; the pipeline checks the selection, then writes the answer over it.
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
    func showPreview(_ names: Set<String>) {
        let french = Locale.preferredLanguages.first?.hasPrefix("fr") == true
        let pinnedState: AskPanelState? =
            if names.contains("ask-listening") {
                .listening
            } else if names.contains("ask-thinking") {
                .thinking
            } else if names.contains("ask-streaming") {
                .streaming
            } else if names.contains("ask-error") {
                .failed(.notRunning(endpoint: server.isEmpty ? "127.0.0.1:8002" : server))
            } else if names.contains("ask") {
                .reviewing
            } else {
                nil
            }
        guard let pinnedState else { return }
        pinned = true
        let sample = AskPreviewSample(french: french)
        quote = AskPresentation.quote(sample.selection)
        instruction = pinnedState == .listening ? nil : sample.instruction
        streamed = pinnedState == .streaming ? String(sample.answer.prefix(70)) : sample.answer
        answer = sample.answer
        if server.isEmpty { server = "127.0.0.1:8002" }
        // `ask-remote` adds the line a cloud profile shows, with a sample host.
        if names.contains("ask-remote") { remoteHost = "api.example.com" }
        state = pinnedState
        panel.open()
    }

    private func closePreview() {
        panel.dismiss()
        state = .closed
    }
}

/// The preview's sample: sample text, not catalog strings.
private struct AskPreviewSample {
    let selection: String
    let instruction: String
    let answer: String

    init(french: Bool) {
        if french {
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
