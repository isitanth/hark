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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            quote
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
                    .textSelection(.enabled)
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
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .listening:
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(L("ask.listening"))
                } icon: {
                    Image(systemName: "waveform")
                }
                .font(.body.weight(.medium))
                Text(L("ask.listening.hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .transcribing:
            progress(L("ask.transcribing"))
        case .thinking:
            progress(namesServer ? L("ask.thinking.server \(model.server)") : L("ask.thinking"))
        case .streaming:
            answer(editable: false)
        case .reviewing:
            answer(editable: true)
        case .failed(let failure):
            Label {
                Text(failure.popupText)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        case .closed:
            EmptyView()
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
            // A hidden copy of the text measures the height; the line after it leaves room for the caret.
            Text(verbatim: text + "\n")
                .font(.body)
                .padding(.horizontal, 5)
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
                button(L("ask.button.copy"), action: model.copy)
                    .buttonStyle(.borderedProminent)
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
