import Foundation
import HarkCore

enum Fixture {
    static let id = UtteranceID(1)
    static let other = UtteranceID(2)
    /// 2026-09-18T14:03:12.345+02:00
    static let pressedAt = Date(timeIntervalSince1970: 1_789_732_992.345)
    /// 2026-09-18T23:59:59.900+02:00
    static let beforeMidnight = Date(timeIntervalSince1970: 1_789_768_799.9)
    static let paris = TimeZone(identifier: "Europe/Paris") ?? .gmt

    static let mail = AppIdentity(bundleID: "com.apple.mail", name: "Mail", processID: 501)
    static let textEdit = AppIdentity(bundleID: "com.apple.TextEdit", name: "TextEdit", processID: 612)
    /// What Services › Ask Hark hands over: a selection in TextEdit. Its words appear in no transcript or answer here,
    /// so a test can look for them in a log line.
    static let selectionText = "Le comité se réunira jeudi à 14 h pour valider le budget du troisième trimestre."
    static let selection = SelectionSnapshot(text: selectionText, caller: textEdit)
    static let ask = CaptureIntent.ask(selection)
    static let instruction = Transcript(raw: "Résume ce texte.", tier: .small)
    static let answer = "Réunion jeudi 14 h : validation du budget T3."
    static let focus = FocusSnapshot(app: mail)
    static let speech = CaptureSummary(durationMs: 1800, peakRMS: 0.3, meanRMS: 0.05)
    static let short = CaptureSummary(durationMs: 120, peakRMS: 0.3, meanRMS: 0.05)
    static let silent = CaptureSummary(durationMs: 1800, peakRMS: 0.001, meanRMS: 0.0005)
    static let maxed = CaptureSummary(durationMs: 60_000, peakRMS: 0.3, meanRMS: 0.05, reachedMaxDuration: true)
    static let transcript = Transcript(raw: "open finder")
    /// The model id MTPLX served for Bonsai 2 27B in M8.0.
    static let bonsai = "mtplx-bonsai-2-27b-optimized-speed"

    static let finder = ResolvedCommand(id: "open_finder", action: .openApp, target: "Finder")
    /// A command that asks first. Nothing in commands.yaml sets `confirm` yet; the reducer keeps the path.
    static let guarded = ResolvedCommand(id: "open_terminal", action: .openApp, target: "Terminal", confirm: true)

    static func context(
        _ id: UtteranceID = id,
        pressedAt: Date = pressedAt,
        focus: FocusSnapshot? = focus,
        released: Bool = true,
        capture: CaptureSummary? = nil,
        transcribeMs: Int? = nil,
        action: ActionType? = nil,
        clipboardFallback: Bool = true,
        intent: CaptureIntent = .dictate,
        llmModel: String? = nil,
        llmMs: Int? = nil
    ) -> UtteranceContext {
        var context = UtteranceContext(id: id, pressedAt: pressedAt, intent: intent)
        context.focus = focus
        context.releasedAt = released ? pressedAt.addingTimeInterval(1.8) : nil
        context.capture = capture
        context.transcribeMs = transcribeMs
        context.action = action
        context.clipboardFallback = clipboardFallback
        context.llmModel = llmModel
        context.llmMs = llmMs
        return context
    }

    static let capturing = PipelineState.capturing(context(focus: nil, released: false))
    static let capturingFocused = PipelineState.capturing(context(released: false))
    static let transcribing = PipelineState.transcribing(context())
    static let transcribingUnfocused = PipelineState.transcribing(context(focus: nil))
    static let transcribingCaptured = PipelineState.transcribing(context(capture: speech))
    static let resolving = PipelineState.resolving(context(capture: speech, transcribeMs: 420), transcript)
    static let awaitingAnswer = PipelineState.confirming(
        context(capture: speech, transcribeMs: 420, action: .openApp), transcript, guarded, .awaitingAnswer)
    static let restoringFocus = PipelineState.confirming(
        context(capture: speech, transcribeMs: 420, action: .openApp), transcript, guarded, .restoringFocus)
    static let acting = PipelineState.acting(
        context(capture: speech, transcribeMs: 420, action: .openApp), transcript, finder)
    static let inserting = PipelineState.inserting(context(capture: speech, transcribeMs: 420), transcript, .axInsert)
    static let insertingWithoutFallback = PipelineState.inserting(
        context(capture: speech, transcribeMs: 420, clipboardFallback: false), transcript, .paste)
    static let copying = PipelineState.copying(context(capture: speech, transcribeMs: 420), transcript, .chosen)
    static let copyingAfterInsertFailed = PipelineState.copying(
        context(capture: speech, transcribeMs: 420), transcript, .fallback(.insertionFailed))

    /// An ask's context: the focus is the caller, set at the press.
    static func askContext(llmModel: String? = nil, llmMs: Int? = nil, released: Bool = true) -> UtteranceContext {
        context(
            focus: FocusSnapshot(app: textEdit), released: released, capture: released ? speech : nil,
            transcribeMs: released ? 380 : nil, intent: ask, llmModel: llmModel, llmMs: llmMs)
    }

    static let askCapturing = PipelineState.capturing(askContext(released: false))
    static let askTranscribing = PipelineState.transcribing(askContext())
    static let generating = PipelineState.asking(askContext(), instruction, .generating)
    static let reviewing = PipelineState.asking(askContext(llmModel: bonsai, llmMs: 2_610), instruction, .reviewing)
    static let replacing = PipelineState.asking(
        {
            var context = askContext(llmModel: bonsai, llmMs: 2_610)
            context.answer = answer
            return context
        }(), instruction, .replacing)
    /// TextEdit in front again, its text view focused and taking an AX insertion.
    static let backInTextEdit = FocusSnapshot(
        app: textEdit, element: FocusedElement(role: "AXTextArea", acceptsSelectedText: true, valueSettable: true))
    static func askFailed(_ failure: LLMFailure, llmMs: Int? = 15_000) -> PipelineState {
        .asking(askContext(llmMs: llmMs), instruction, .failed(failure))
    }
}

extension PipelineEffect {
    /// Compact form for test tables, for example `startCapture` or `log:failed:model_missing:small`.
    var label: String {
        switch self {
        case .startCapture: "startCapture"
        case .probeFocus: "probeFocus"
        case .stopCapture: "stopCapture"
        case .cancelCapture: "cancelCapture"
        case .transcribe: "transcribe"
        case .cancelTranscription: "cancelTranscription"
        case .resolve: "resolve"
        case .requestConfirmation: "requestConfirmation"
        case .dismissConfirmation: "dismissConfirmation"
        case .restoreFocus: "restoreFocus"
        case .runAction: "runAction"
        case .insert: "insert"
        case .copyToClipboard: "copyToClipboard"
        case .generate: "generate"
        case .cancelGeneration: "cancelGeneration"
        case .checkSelection: "checkSelection"
        case .writeLog(let record):
            (["log", record.resolution.rawValue] + [record.error].compactMap(\.self)).joined(separator: ":")
        }
    }

    var record: UtteranceRecord? {
        if case .writeLog(let record) = self { record } else { nil }
    }
}
