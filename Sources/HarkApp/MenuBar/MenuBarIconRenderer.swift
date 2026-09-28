import AppKit
import HarkCore

/// Draws every state on the same 18×18 pt template canvas, so the status item never changes width.
/// Template only: states differ by symbol and alpha, never by colour.
enum MenuBarIconRenderer {
    static let size = NSSize(width: 18, height: 18)

    static func image(for state: MenuBarIconState) -> NSImage {
        let name = state.symbolName
        let alpha = state.alpha
        let image = NSImage(size: size, flipped: false) { rect in
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            guard
                let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)
            else { return false }
            let scale = min(rect.width / symbol.size.width, rect.height / symbol.size.height, 1)
            let drawn = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            let origin = NSPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)
            symbol.draw(in: NSRect(origin: origin, size: drawn), from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension MenuBarIconState {
    var symbolName: String {
        switch self {
        case .idle, .transcribing: "waveform"
        case .recording: "record.circle"
        case .armed: "waveform.badge.mic"
        case .error: "exclamationmark.triangle"
        }
    }

    var alpha: CGFloat {
        self == .transcribing ? 0.6 : 1
    }

    var label: LocalizedStringResource {
        switch self {
        case .idle: L("state.idle")
        case .recording: L("state.recording")
        case .transcribing: L("state.transcribing")
        case .armed: L("state.armed")
        case .error: L("state.error")
        }
    }
}
