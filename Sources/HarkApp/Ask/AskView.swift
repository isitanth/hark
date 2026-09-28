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

    /// A legacy scroller's width: the editor's text column is this much narrower when scroll bars always show.
    private static let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    var body: some View {
        // The header, the quote and the status lines take no clicks, so a press there reaches the background and
        // drags the panel, as a title bar would.
        VStack(alignment: .leading, spacing: 12) {
            header
                .allowsHitTesting(false)
            if !model.quote.isEmpty {
                quote
                    .allowsHitTesting(false)
            }
            // The assistant has no quote, and still says when the request leaves this Mac.
            if model.quote.isEmpty, let host = model.remoteHost {
                remote(host)
                    .allowsHitTesting(false)
            }
            content
            footer
        }
        .padding(16)
        .frame(width: AskPanel.width, alignment: .leading)
        .background(AskPanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
        )
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
            Image(systemName: model.state == .listening ? "mic.fill" : "text.bubble")
                .foregroundStyle(model.state == .listening ? Color.red : Color.accentColor)
            if let instruction = model.instruction {
                Text(verbatim: instruction)
                    .font(.headline)
                    .lineLimit(3)
            } else {
                Text(L("ask.title"))
                    .font(.headline)
            }
        }
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
        case .transcribing:
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
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            switch model.state {
            case .listening:
                button(L("ask.button.cancel"), action: model.cancel)
                button(L("ask.button.done"), action: model.done)
                    .keyboardShortcut(.defaultAction)
            case .transcribing, .thinking, .streaming:
                button(L("ask.button.cancel"), action: model.cancel)
            case .reviewing:
                button(L("ask.button.cancel"), action: model.cancel)
                switch model.apply {
                case .replace, .insert:
                    button(L("ask.button.copy"), action: model.copy)
                    button(
                        model.apply == .insert ? L("ask.button.insert") : L("ask.button.replace"), action: model.replace
                    )
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                case .copyOnly:
                    button(L("ask.button.copy"), action: model.copy)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
            case .failed:
                button(L("ask.button.cancel"), action: model.cancel)
                button(L("ask.button.copyInstruction"), action: model.copyInstruction)
                    .disabled(model.instruction == nil)
                button(L("ask.button.retry"), action: model.retry)
                    .keyboardShortcut(.defaultAction)
            case .closed:
                EmptyView()
            }
        }
    }

    private func button(_ title: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
        }
    }
}

private struct AnswerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
