import HarkCore
import SwiftUI

/// A conversation's earlier turns above the live one: plain rows, not glass, folded to the instruction and the
/// answer's first line; a click unfolds one. They scroll within `maxHeight`, anchored to the newest, and report the
/// height they take so the live answer has the rest of the panel's 60%.
struct AskTranscript: View {
    let model: AskPanelModel
    let maxHeight: CGFloat
    @Binding var shownHeight: CGFloat
    @State private var unfolded: Set<UtteranceID> = []
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.turns.enumerated()), id: \.element.id) { index, turn in
                    row(turn, number: index + 1)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: TranscriptHeightKey.self, value: proxy.size.height)
                })
        }
        .defaultScrollAnchor(.bottom)
        .askScrollEdge()
        .frame(height: min(contentHeight, maxHeight))
        .onPreferenceChange(TranscriptHeightKey.self) { height in
            contentHeight = height
            shownHeight = min(height, maxHeight)
        }
        .onDisappear { shownHeight = 0 }
    }

    private func row(_ turn: AskTurnRow, number: Int) -> some View {
        let open = unfolded.contains(turn.id)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if open { unfolded.remove(turn.id) } else { unfolded.insert(turn.id) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: turn.instruction)
                            .font(.callout.weight(.medium))
                            .lineLimit(open ? nil : 1)
                        if !open {
                            Text(verbatim: turn.firstLine)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    thumbnail(turn)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L("ask.turn.label \(number)")))
            .accessibilityValue(Text(verbatim: turn.instruction))
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    if let restatement = turn.restatement {
                        AskRestatement(text: restatement)
                    }
                    Text(verbatim: turn.answer)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 18)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }

    /// A follow-up's own frame; turn 1's stays on its fixed chip above.
    @ViewBuilder
    private func thumbnail(_ turn: AskTurnRow) -> some View {
        if turn.id != model.threadRoot, turn.region != nil, let image = model.regionThumbnails[turn.id] {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 28)
                .askClip(minimum: 3)
                .accessibilityHidden(true)
        }
    }
}

private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
