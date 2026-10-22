import HarkCore
import SwiftUI

/// The Ask panel's content, top to bottom: the instruction, a quote of the selection, the state or the answer, and
/// the buttons. It renders `AskPanelModel` and computes nothing.
struct AskView: View {
    @Bindable var model: AskPanelModel
    @FocusState private var editing: Bool
    /// "Thinking…" has stood alone long enough to name the server it waits for.
    @State private var namesServer = false
    @State private var answerHeight: CGFloat = 0
    /// The chips and the footer groups morph within it on macOS 26.
    @Namespace private var glass
    /// Hark's own fills turn opaque; the system frosts the glass itself.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// A legacy scroller's width: the editor's text column is this much narrower when scroll bars always show.
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
            if let intent = model.intent {
                AskRestatement(text: intent)
            }
            content
            footer
        }
        .padding(16)
        .frame(width: AskPanel.width, alignment: .leading)
        .askPanelChrome()
        .task(id: model.state) {
            namesServer = false
            guard model.state == .thinking else { return }
            try? await Task.sleep(for: AskPresentation.namesServerAfter)
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
                Text(verbatim: instruction)
                    .font(headlineFont)
                    .lineLimit(3)
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
        default:
            status
                .allowsHitTesting(false)
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
                Text(model.quote.isEmpty ? L("assistant.listening.hint") : L("ask.listening.hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                preflight
            }
        case .transcribing, .awaitingRegion:
            VStack(alignment: .leading, spacing: 4) {
                progress(L("ask.transcribing"))
                preflight
            }
        case .thinking:
            progress(namesServer ? L("ask.thinking.server \(model.server)") : L("ask.thinking"))
        case .failed(let failure):
            Label {
                Text(failure.popupText)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        case .regionFailed:
            Label {
                Text(L("ask.failure.streamError"))
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
        return Group {
            if editable {
                TextEditor(text: $model.answer)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($editing)
            } else {
                ScrollView {
                    Text(verbatim: text)
                        .font(.body)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .askScrollEdge()
        .frame(height: min(max(answerHeight, 44), model.maxAnswerHeight))
        .background(alignment: .topLeading) {
            // A hidden copy of the text measures the height; the line after it leaves room for the caret. It wraps
            // a scroller's width early, as the editor does when scroll bars always show.
            Text(verbatim: text + "\n")
                .font(.body)
                .padding(.leading, 5)
                .padding(.trailing, 5 + Self.scrollerWidth)
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

    /// [Cancel] leading; on glass, the secondary actions grouped and the primary alone at the trailing edge. Below
    /// macOS 26, today's row at the trailing edge.
    @ViewBuilder
    private var footer: some View {
        let layout = footerLayout
        if #available(macOS 26, *) {
            HStack(spacing: 8) {
                if layout.cancel {
                    footerButton(cancelAction, prominent: false)
                        .askChipID(cancelAction.id, in: glass)
                }
                Spacer(minLength: 8)
                if !layout.secondary.isEmpty {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(layout.secondary) { action in
                                footerButton(action, prominent: false)
                                    .askChipID(action.id, in: glass)
                            }
                        }
                    }
                }
                if let primary = layout.primary {
                    footerButton(primary, prominent: true)
                        .askChipID(primary.id, in: glass)
                }
            }
        } else {
            HStack(spacing: 8) {
                Spacer()
                if layout.cancel {
                    footerButton(cancelAction, prominent: false)
                }
                ForEach(layout.secondary) { action in
                    footerButton(action, prominent: false)
                }
                if let primary = layout.primary {
                    footerButton(primary, prominent: true)
                }
            }
        }
    }

    private var cancelAction: FooterAction {
        FooterAction(id: "cancel", title: L("ask.button.cancel"), action: model.cancel)
    }

    /// The buttons each state offers. Replace only when the ask allows it: an image has no text to replace.
    private var footerLayout: FooterLayout {
        switch model.state {
        case .listening:
            return FooterLayout(
                primary: FooterAction(
                    id: "done", title: L("ask.button.done"), action: model.done, shortcut: .defaultAction))
        case .transcribing, .awaitingRegion, .thinking, .streaming, .regionFailed:
            return FooterLayout()
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
        case .failed:
            return FooterLayout(
                secondary: [
                    FooterAction(
                        id: "copyInstruction", title: L("ask.button.copyInstruction"),
                        action: model.copyInstruction, disabled: model.instruction == nil)
                ],
                primary: FooterAction(
                    id: "retry", title: L("ask.button.retry"), action: model.retry, shortcut: .defaultAction))
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
