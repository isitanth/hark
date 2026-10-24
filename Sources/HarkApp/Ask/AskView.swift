import HarkCore
import KeyboardShortcuts
import SwiftUI

/// The Ask panel's content, top to bottom: the instruction, a quote of the selection, the state or the answer, and
/// the buttons. It renders `AskPanelModel` and computes nothing.
struct AskView: View {
    @Bindable var model: AskPanelModel
    @FocusState private var editing: Bool
    /// "Thinking…" has stood alone long enough to name the server it waits for.
    @State private var namesServer = false
    @State private var answerHeight: CGFloat = 0
    /// What the earlier turns of a conversation take of the 60%.
    @State private var transcriptHeight: CGFloat = 0
    /// The chips and the footer groups morph within it on macOS 26.
    @Namespace private var glass
    /// Hark's own fills turn opaque; the system frosts the glass itself.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The most the earlier turns take of the panel's 60%; the live answer has the rest.
    private static let transcriptShare: CGFloat = 0.4
    /// The live answer's least height beside the earlier turns.
    private static let minimumAnswerCap: CGFloat = 120

    /// A legacy scroller's width: the editor's text column is this much narrower once it scrolls with scroll bars
    /// always shown.
    private static let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    var body: some View {
        // The header, the quote and the status lines take no clicks, so a press there reaches the background and
        // drags the panel, as a title bar would.
        VStack(alignment: .leading, spacing: 12) {
            header
                .allowsHitTesting(false)
            AskChips(model: model, namespace: glass, removable: model.state.isCapturing)
            // On glass the chips carry the selection and the host; below, the quote bar and the remote line do.
            if !AskGlass.isAvailable, !model.quote.isEmpty {
                quote
                    .allowsHitTesting(false)
            }
            // The assistant has no quote, and still says when the request leaves this Mac.
            if !AskGlass.isAvailable, model.quote.isEmpty, let host = model.remoteHost {
                remote(host)
                    .allowsHitTesting(false)
            }
            if !model.turns.isEmpty {
                AskTranscript(
                    model: model, maxHeight: model.maxAnswerHeight * Self.transcriptShare,
                    shownHeight: $transcriptHeight)
            }
            if let intent = model.intent {
                AskRestatement(text: intent)
            }
            content
            footerLine
                .allowsHitTesting(false)
            footer
                .askAppearsActive()
        }
        .padding(16)
        .frame(width: AskPanel.width, alignment: .leading)
        .askPanelChrome()
        // While ⌃⌥ frame part of the screen the panel steps back, so what lies under it shows.
        .opacity(model.isFraming ? 0.35 : 1)
        .allowsHitTesting(!model.isFraming)
        // A change of state morphs the footer groups and the chips on glass; under Reduce Motion, and below macOS 26
        // where the panel keeps today's look, it is immediate.
        .animation(morphs ? .smooth(duration: 0.3) : nil, value: model.state)
        .animation(morphs ? .smooth(duration: 0.3) : nil, value: model.regionPixelSize)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.isFraming)
        .task(id: model.state) {
            namesServer = false
            guard model.state == .thinking else { return }
            try? await Task.sleep(
                for: model.sentFrame ? AskPresentation.namesServerAfterFrame : AskPresentation.namesServerAfter)
            namesServer = !Task.isCancelled
        }
        .onChange(of: model.state) { _, state in
            editing = state == .reviewing
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: headerSymbol)
                .foregroundStyle(model.state == .listening ? Color.red : Color.accentColor)
            if let instruction = model.instruction {
                // Never squeezed: the content's height has a fraction of a point the window rounds away, and a
                // compressible headline gave up its second line to it (French, measured).
                Text(verbatim: instruction)
                    .font(headlineFont)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(L("ask.title"))
                    .font(headlineFont)
            }
        }
    }

    /// The instruction, bolder on glass: hierarchy from type, not boxes.
    private var headlineFont: Font {
        AskGlass.isAvailable ? .title3.weight(.semibold) : .headline
    }

    /// The microphone while listening; on glass, sparkles once the model works on it, as today's bubble below.
    private var headerSymbol: String {
        if model.state == .listening { return "mic.fill" }
        return AskGlass.isAvailable ? "sparkles" : "text.bubble"
    }

    private var quote: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.tertiary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.quote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if model.truncated {
                    Text(L("ask.truncated \(model.maxSelectionChars)"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let host = model.remoteHost {
                    remote(host)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func remote(_ host: String) -> some View {
        Label {
            Text(L("ask.remote \(host)"))
        } icon: {
            Image(systemName: "network")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// The answer takes clicks; every other state is a status line that lets a press drag the panel.
    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .streaming:
            answer(editable: false)
        case .reviewing:
            answer(editable: true)
        case .listening:
            VStack(alignment: .leading, spacing: 8) {
                status
                    .allowsHitTesting(false)
                framing
            }
        default:
            status
                .allowsHitTesting(false)
        }
    }

    private var hasRegion: Bool { model.regionThumbnail != nil || model.regionPixelSize != nil }

    /// What to say while listening: about the selection, the frame, both, or neither (the assistant).
    private var listeningHint: LocalizedStringResource {
        // A follow-up changes the last answer, and Esc goes back to it.
        if model.isFollowUp { return hasRegion ? L("ask.followUp.hint.frame") : L("ask.followUp.hint") }
        return switch (model.quote.isEmpty, hasRegion) {
        case (true, false): L("assistant.listening.hint")
        case (false, false): L("ask.listening.hint")
        case (true, true): L("assistant.listening.hint.frame")
        case (false, true): L("ask.listening.hint.frame")
        }
    }

    /// How to frame, from the Ask key: held, a key that has ⌃ or ⌥ already needs only the other one. A follow-up adds
    /// part of the screen to the conversation.
    private var frameHint: LocalizedStringResource {
        guard let key = KeyboardShortcuts.getShortcut(for: .ask) else {
            return model.isFollowUp ? L("ask.followUp.frameHint") : L("ask.listening.frameHint")
        }
        let held = key.description
        let control = "⌃"
        let option = "⌥"
        let follow = model.isFollowUp
        switch (key.modifiers.contains(.control), key.modifiers.contains(.option)) {
        case (true, true):
            return follow ? L("ask.followUp.frameHint.held \(held)") : L("ask.listening.frameHint.held \(held)")
        case (true, false):
            return follow
                ? L("ask.followUp.frameHint.add \(held) \(option)") : L("ask.listening.frameHint.add \(held) \(option)")
        case (false, true):
            return follow
                ? L("ask.followUp.frameHint.add \(held) \(control)")
                : L("ask.listening.frameHint.add \(held) \(control)")
        case (false, false):
            return follow ? L("ask.followUp.frameHint") : L("ask.listening.frameHint")
        }
    }

    /// Above the buttons: the busy nudge while it lasts, else in review how to follow up, or that the conversation is
    /// full.
    @ViewBuilder
    private var footerLine: some View {
        if model.showsBusyNudge {
            Label {
                Text(busyNudge)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
        } else if model.flashesFull {
            Label {
                Text(L("ask.footer.full"))
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if model.state == .reviewing, let hint = model.footerHint {
            Text(footerText(hint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// The Cancel key reaches the panel from any app; a plain Esc only while the panel is key.
    private var busyNudge: LocalizedStringResource {
        guard let key = KeyboardShortcuts.getShortcut(for: .cancelUtterance) else { return L("ask.busyNudge") }
        let shortcut = key.description
        return L("ask.busyNudge.key \(shortcut)")
    }

    private func footerText(_ hint: AskFooterHint) -> LocalizedStringResource {
        switch hint {
        case .full:
            return L("ask.footer.full")
        case .followUp(let turn, let max):
            guard let key = KeyboardShortcuts.getShortcut(for: .ask) else {
                return L("ask.footer.followUp.unset \(turn) \(max)")
            }
            let held = key.description
            return L("ask.footer.followUp \(held) \(turn) \(max)")
        }
    }

    /// While listening: how to show Hark the screen, or why it cannot see it now, with the button that fixes it.
    @ViewBuilder
    private var framing: some View {
        if let block = model.framingBlocked {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(block.text(requested: model.screenRecordingRequested))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "eye.slash")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                framingButton(block)
                    .controlSize(.small)
                    .askButtonStyle(prominent: false)
                    // Outside the footer, so its own: not key, its label fell to 92,92,92 beside the footer's white
                    // (sdk 27, measured 2026-10-24). On the button alone, as on the footer.
                    .askAppearsActive()
            }
        } else if !hasRegion {
            Text(frameHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func framingButton(_ block: FramingBlock) -> some View {
        switch block {
        case .noScreenRecording where model.screenRecordingRequested:
            Button(action: model.reopenForScreenRecording) { Text(L("ask.button.reopen")) }
        case .noScreenRecording:
            Button(action: model.allowScreenRecording) { Text(L("ask.button.allow")) }
        case .modelCannotSee:
            Button(action: model.chooseAnotherModel) { Text(L("ask.button.chooseModel")) }
        case .framesFull:
            EmptyView()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .listening:
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(L("ask.listening"))
                } icon: {
                    Image(systemName: "waveform")
                }
                .font(.body.weight(.medium))
                Text(listeningHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                preflight
            }
        case .transcribing:
            VStack(alignment: .leading, spacing: 4) {
                progress(L("ask.transcribing"))
                preflight
            }
        case .awaitingRegion:
            VStack(alignment: .leading, spacing: 4) {
                progress(L("ask.awaitingRegion"))
                preflight
            }
        case .thinking:
            progress(
                namesServer
                    ? L("ask.thinking.server \(model.server)")
                    : model.sentFrame ? L("ask.thinking.frame") : L("ask.thinking"))
        case .failed(let failure):
            Label {
                Text(failure.popupText(imageAttached: hasRegion || model.sentFrame))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        case .regionFailed(let failure):
            Label {
                Text(failure.popupText)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        case .streaming, .reviewing, .closed:
            EmptyView()
        }
    }

    /// The pre-flight's finding, before the instruction is sent: the server will not answer it as things stand.
    @ViewBuilder
    private var preflight: some View {
        if let failure = model.preflightFailure {
            Label {
                Text(failure.popupText)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
            .padding(.top, 4)
        }
    }

    private func progress(_ text: LocalizedStringResource) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    /// The answer, as tall as its text up to 60% of the screen, then scrolling. Read-only while it streams, pinned to
    /// its last line; editable once complete.
    private func answer(editable: Bool) -> some View {
        let text = editable ? model.answer : model.streamed
        let height = min(max(answerHeight, 44), answerCap)
        return Group {
            if editable {
                TextEditor(text: $model.answer)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($editing)
            } else {
                ScrollView {
                    // As tall as the box while it fits, its text at the top: the bottom anchor put a short answer at
                    // the box's bottom, under the 44 pt floor. It follows the stream once the answer scrolls.
                    Text(verbatim: text)
                        .font(.body)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .askScrollEdge()
        // No scroller while the answer fits: on macOS 26 a legacy one that has nothing to scroll still draws its knob.
        .scrollIndicators(answerHeight > answerCap ? .automatic : .never)
        .frame(height: height)
        .background(alignment: .topLeading) {
            // A hidden copy of the text measures the height. In review, the line after it leaves room for the caret,
            // and it wraps a scroller's width early, as the editor does once it scrolls; while it fits, the column is
            // wider and the measure can only be high. While it streams, the text alone at the width it shows at: the
            // caret's line showed blank above the streaming text, which then sat a line below the editor's at the
            // switch to review and cross-faded into it twice (measured 2026-10-24: first line 25 pt under the box's
            // top streaming, 9 pt in review; 9 pt in both now).
            Text(verbatim: editable ? text + "\n" : text)
                .font(.body)
                .padding(.leading, 5)
                .padding(.trailing, editable ? 5 + Self.scrollerWidth : 5)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: AnswerHeightKey.self, value: proxy.size.height)
                    })
        }
        .onPreferenceChange(AnswerHeightKey.self) { height in
            answerHeight = height
        }
        .padding(6)
        .askFill(.background.opacity(reduceTransparency ? 1 : 0.6), minimum: AskGlass.innerRadius)
    }

    /// The 60% less what the earlier turns take, never under `minimumAnswerCap`.
    private var answerCap: CGFloat {
        guard !model.turns.isEmpty else { return model.maxAnswerHeight }
        return max(model.maxAnswerHeight - transcriptHeight, Self.minimumAnswerCap)
    }

    /// [Cancel] leading; on glass, the secondary actions grouped and the primary alone at the trailing edge. Below
    /// macOS 26, today's row at the trailing edge. Labels wider than the panel (French, four buttons) put the secondary
    /// actions on a row of their own above, rather than cut one short.
    private var footer: some View {
        let layout = footerLayout
        return ViewThatFits(in: .horizontal) {
            footerRow(layout, secondary: true)
            VStack(alignment: .trailing, spacing: 8) {
                secondaryGroup(layout)
                footerRow(layout, secondary: false)
            }
        }
    }

    @ViewBuilder
    private func footerRow(_ layout: FooterLayout, secondary: Bool) -> some View {
        if #available(macOS 26, *) {
            HStack(spacing: 8) {
                if layout.cancel {
                    footerButton(cancelAction, prominent: false)
                        .askChipID(cancelAction.id, in: glass)
                }
                Spacer(minLength: 8)
                if secondary {
                    secondaryGroup(layout)
                }
                if let primary = layout.primary {
                    footerButton(primary, prominent: true)
                        .askChipID(primary.id, in: glass)
                }
            }
        } else {
            // Today's look: only the answer's Replace, Insert or Copy is prominent; Done and Retry stay plain.
            HStack(spacing: 8) {
                Spacer()
                if layout.cancel {
                    footerButton(cancelAction, prominent: false)
                }
                if secondary {
                    secondaryGroup(layout)
                }
                if let primary = layout.primary {
                    footerButton(primary, prominent: model.state == .reviewing)
                }
            }
        }
    }

    /// The secondary actions side by side; on glass, in one container.
    @ViewBuilder
    private func secondaryGroup(_ layout: FooterLayout) -> some View {
        if layout.secondary.isEmpty {
            EmptyView()
        } else if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(layout.secondary) { action in
                        footerButton(action, prominent: false)
                            .askChipID(action.id, in: glass)
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ForEach(layout.secondary) { action in
                    footerButton(action, prominent: false)
                }
            }
        }
    }

    /// State changes morph on glass only, and never under Reduce Motion.
    private var morphs: Bool {
        if #available(macOS 26, *) { !reduceMotion } else { false }
    }

    /// Before a follow-up's request leaves, Cancel goes back to the answer; after, it ends the conversation.
    private var cancelAction: FooterAction {
        FooterAction(
            id: "cancel", title: goesBack ? L("ask.button.back") : L("ask.button.cancel"), action: model.cancel)
    }

    private var goesBack: Bool {
        guard model.isFollowUp else { return false }
        switch model.state {
        case .listening, .transcribing, .awaitingRegion, .regionFailed: return true
        default: return false
        }
    }

    private var askWithoutImage: FooterAction {
        FooterAction(id: "askWithoutImage", title: L("ask.button.askWithoutImage"), action: model.askWithoutRegion)
    }

    /// The buttons each state offers. Replace only when the ask allows it: an image has no text to replace.
    private var footerLayout: FooterLayout {
        switch model.state {
        case .listening:
            return FooterLayout(
                primary: FooterAction(
                    id: "done", title: L("ask.button.done"), action: model.done, shortcut: .defaultAction))
        case .transcribing, .awaitingRegion, .thinking, .streaming:
            return FooterLayout()
        case .regionFailed(.screenRecordingDenied):
            let allow =
                model.screenRecordingRequested
                ? FooterAction(id: "reopen", title: L("ask.button.reopen"), action: model.reopenForScreenRecording)
                : FooterAction(id: "allow", title: L("ask.button.allow"), action: model.allowScreenRecording)
            return FooterLayout(secondary: [askWithoutImage], primary: allow.with(shortcut: .defaultAction))
        case .regionFailed(.captureFailed):
            return FooterLayout(primary: askWithoutImage.with(shortcut: .defaultAction))
        case .reviewing:
            let copy = FooterAction(id: "copy", title: L("ask.button.copy"), action: model.copy)
            let applies =
                switch model.apply {
                case .insert: true
                case .replace: model.allowsReplace
                case .copyOnly: false
                }
            guard applies else {
                return FooterLayout(primary: copy.with(shortcut: .init(.return, modifiers: .command)))
            }
            let title = model.apply == .insert ? L("ask.button.insert") : L("ask.button.replace")
            return FooterLayout(
                secondary: [copy],
                primary: FooterAction(
                    id: "apply", title: title, action: model.replace,
                    shortcut: .init(.return, modifiers: .command)))
        case .failed(let failure):
            let copyInstruction = FooterAction(
                id: "copyInstruction", title: L("ask.button.copyInstruction"), action: model.copyInstruction,
                disabled: model.instruction == nil)
            let retry = FooterAction(
                id: "retry", title: L("ask.button.retry"), action: model.retry, shortcut: .defaultAction)
            switch failure {
            case .noVision where !model.offersAskWithoutImage:
                // An earlier turn's frame goes with every retry, so dropping this one would fail the same way: the
                // text says why, and Esc ends it.
                let choose = FooterAction(
                    id: "chooseModel", title: L("ask.button.chooseModel"), action: model.chooseAnotherModel)
                return FooterLayout(primary: choose)
            case .noVision(_, .needsMTPMode):
                // The same image to the same AR server fails again: asking without the frame is the way out, and
                // Retry stays for after a restart in MTP mode.
                let retryAfterRestart = FooterAction(id: "retry", title: L("ask.button.retry"), action: model.retry)
                return FooterLayout(
                    secondary: [retryAfterRestart], primary: askWithoutImage.with(shortcut: .defaultAction))
            case .noVision:
                // Retrying the same model is pointless: the image goes, or the model changes. Asking without the
                // image keeps the instruction, so Copy instruction gives way, and the French labels fit.
                let choose = FooterAction(
                    id: "chooseModel", title: L("ask.button.chooseModel"), action: model.chooseAnotherModel)
                return FooterLayout(secondary: [choose], primary: askWithoutImage.with(shortcut: .defaultAction))
            case .profileChanged:
                // A retry goes to the same pinned profile and fails the same way: close, then ask again.
                return FooterLayout(primary: copyInstruction)
            default:
                return FooterLayout(
                    secondary: model.offersAskWithoutImage ? [copyInstruction, askWithoutImage] : [copyInstruction],
                    primary: retry)
            }
        case .closed:
            return FooterLayout(cancel: false)
        }
    }

    private func footerButton(_ footer: FooterAction, prominent: Bool) -> some View {
        Button(action: footer.action) {
            Text(footer.title)
        }
        .keyboardShortcut(footer.shortcut)
        .disabled(footer.disabled)
        .askButtonStyle(prominent: prominent)
    }
}

/// One footer button: its glass identity, its words, what it calls and its shortcut.
private struct FooterAction: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let action: () -> Void
    var shortcut: KeyboardShortcut?
    var disabled = false

    func with(shortcut: KeyboardShortcut) -> FooterAction {
        var copy = self
        copy.shortcut = shortcut
        return copy
    }
}

private struct FooterLayout {
    var cancel = true
    var secondary: [FooterAction] = []
    var primary: FooterAction?
}

private struct AnswerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension AskPanelState {
    /// The instruction is still being captured: the frame can still be removed.
    fileprivate var isCapturing: Bool {
        switch self {
        case .listening, .transcribing, .awaitingRegion: true
        default: false
        }
    }
}
