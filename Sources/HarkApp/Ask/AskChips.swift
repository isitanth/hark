import HarkCore
import SwiftUI

/// What the ask carries, under the headline: the framed region, the selection's first words, and the host when the
/// request leaves this Mac. On macOS 26 they are glass chips in one container and replace the quote bar and the
/// remote line; below, only the region is a chip, on a plain fill, and the quote bar stays. In a conversation, turn 1's
/// chips stay fixed, with no ×, and a follow-up's own frame joins them, removable until the turn is sent.
struct AskChips: View {
    let model: AskPanelModel
    /// Chips and footer groups morph within it.
    let namespace: Namespace.ID
    var removable: Bool

    /// The selection chip's text, in characters.
    private static let selectionChars = 40

    var body: some View {
        if #available(macOS 26, *) {
            if hasRegion || model.rootFrame != nil || !model.quote.isEmpty || model.remoteHost != nil {
                GlassEffectContainer(spacing: 6) {
                    row(selection: true, destination: true)
                }
            }
        } else if hasRegion || model.rootFrame != nil {
            row(selection: false, destination: false)
        }
    }

    private var hasRegion: Bool { model.regionThumbnail != nil || model.regionPixelSize != nil }

    private func row(selection: Bool, destination: Bool) -> some View {
        HStack(spacing: 6) {
            if let root = model.rootFrame {
                regionChip(thumbnail: root.thumbnail, size: root.size, removable: false)
                    .askChipID("rootRegion", in: namespace)
            }
            if hasRegion {
                regionChip(thumbnail: model.regionThumbnail, size: model.regionPixelSize, removable: removable)
                    .askChipID("region", in: namespace)
                    .askMaterialize()
            }
            if selection, !model.quote.isEmpty {
                selectionChip
                    .askChipID("selection", in: namespace)
            }
            if destination, let host = model.remoteHost {
                destinationChip(host)
                    .askChipID("destination", in: namespace)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func regionChip(thumbnail: CGImage?, size: CGSize?, removable: Bool) -> some View {
        HStack(spacing: 8) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 44)
                    .askClip(minimum: 4)
                    .accessibilityHidden(true)
            }
            if let size {
                Text(verbatim: "\(Int(size.width)) × \(Int(size.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if removable {
                Button(action: model.removeRegion) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(L("ask.chip.removeRegion")))
            }
        }
        .padding(4)
        .padding(.trailing, removable ? 2 : 6)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("ask.chip.region")))
        .askChipSurface(interactive: removable)
    }

    private var selectionChip: some View {
        let quote = model.quote
        let opening =
            quote.count > Self.selectionChars ? String(quote.prefix(Self.selectionChars)) + "…" : quote
        return Label {
            Text(verbatim: opening)
                .lineLimit(1)
        } icon: {
            Image(systemName: "text.quote")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxHeight: .infinity)
        .askChipSurface(interactive: false)
        .help(model.truncated ? Text(L("ask.truncated \(model.maxSelectionChars)")) : Text(verbatim: quote))
        .layoutPriority(-1)
    }

    private func destinationChip(_ host: String) -> some View {
        Label {
            Text(verbatim: host)
                .lineLimit(1)
        } icon: {
            Image(systemName: "network")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxHeight: .infinity)
        .askChipSurface(interactive: false)
        .help(Text(L("ask.remote \(host)")))
        .accessibilityLabel(Text(L("ask.remote \(host)")))
    }
}

/// An image ask's restatement of what the user is after, under the chips: no box, three lines, the rest as help.
struct AskRestatement: View {
    let text: String

    var body: some View {
        Label {
            // In the primary colour, after "Understood:": the model's reading of the request, the line to check.
            Text(L("ask.intent \(text)"))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .help(text)
    }
}
