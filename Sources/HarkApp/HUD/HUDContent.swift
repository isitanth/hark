import HarkCore
import SwiftUI

/// The HUD's face: the spectrum on the left, the timer on the right, one line under them for the status or the
/// live text.
///
/// Fixed at 280×64, so nothing that changes inside it can resize the panel thirty times a second. The bars take the
/// full 40 pt when the top row is alone and shrink to 24 pt when the second row shows, so the block stays centred.
/// It holds no control, so nothing in it can ask for key; the whole of it is hidden from VoiceOver, which would
/// otherwise read a floating window's changing text or land on it.
struct HUDContent: View {
    let model: HUDModel

    var body: some View {
        let second = secondLine
        let barHeight: CGFloat = second == nil ? 40 : 24
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                HUDBars(levels: model.bars.bars, maxHeight: barHeight)
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 4) {
                    if model.face == .listening(handsFree: true) {
                        Image(systemName: "lock.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: model.timerText)
                        .monospacedDigit()
                }
                .font(.system(size: 15, weight: .medium))
            }
            .frame(height: barHeight)
            if let second {
                second
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 18)
        .frame(width: HUDPanel.size.width, height: HUDPanel.size.height)
        .accessibilityHidden(true)
    }

    /// The status when there is one, else the live text while listening, else nothing.
    private var secondLine: Text? {
        if let status { return Text(status) }
        if case .listening = model.face, let line = model.liveLine { return Text(verbatim: line) }
        return nil
    }

    private var status: LocalizedStringResource? {
        switch model.face {
        case .transcribing(.limitReached): L("hud.status.limitReached")
        case .transcribing(.longClip): L("hud.status.transcribing")
        case .hidden, .listening: nil
        }
    }
}

/// Seven capsules centred on one line, growing the same up and down, the lowest pitch in the middle, like Apple
/// Music's visualizer. `SpectrumBins` computes the levels and their order; this only scales them, from a 6 pt circle
/// at rest to `maxHeight`. Each value is drawn as given, with no implicit animation.
private struct HUDBars: View {
    static let width: CGFloat = 6
    let levels: [Float]
    let maxHeight: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(levels.indices, id: \.self) { bar in
                Capsule()
                    .frame(width: Self.width, height: Self.width + (maxHeight - Self.width) * CGFloat(levels[bar]))
            }
        }
        .frame(height: maxHeight)
        .foregroundStyle(.primary)
        .transaction { $0.animation = nil }
    }
}
