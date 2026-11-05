import AppKit
import HarkCore

/// `-HarkDebugPreview overlay-layer`: c01's invoices as a stand-in window drawn in code, and the layer's tints over it,
/// for screenshots. No capture and no search: the cells are placed where the stand-in draws them.
enum RegionLayerSample {
    static let rows = 12
    static let rowHeight: CGFloat = 40
    static let header: CGFloat = 60
    static let size = CGSize(width: 700, height: 600)
    /// c01: the credit notes subtract, January's refunded invoice is left out, one cell may be misread.
    static let subtracted: Set<Int> = [2, 5, 9]
    static let excluded = 12
    static let uncertain = 5

    /// The cells, in the zone's points from its top-left corner; the zone is the stand-in's content.
    static var cells: [HighlightedCell] {
        (1...rows).filter { $0 != excluded }.map { row in
            let box = CGRect(
                x: size.width * 0.45, y: header + CGFloat(row - 1) * rowHeight + 8, width: size.width * 0.2,
                height: rowHeight - 16
            ).insetBy(dx: -AskPresentation.cellPadding, dy: -AskPresentation.cellPadding)
            return HighlightedCell(
                id: CellID(row * 4 + 3), box: box, role: subtracted.contains(row) ? .subtracted : .added,
                uncertain: row == uncertain)
        }
    }

    /// A plain window on the main display, centred, its content the sample table.
    static func standIn() -> NSWindow {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(
            x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height
        ).integral
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = Table(frame: CGRect(origin: .zero, size: size))
        window.orderFrontRegardless()
        return window
    }

    /// White rows, grey rules and dark bars where the text would be.
    private final class Table: NSView {
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            bounds.fill()
            for row in 0...rows {
                let y = header + CGFloat(row) * rowHeight
                NSColor(white: 0.85, alpha: 1).setFill()
                CGRect(x: 16, y: y, width: bounds.width - 32, height: 1).fill()
                guard row < rows else { continue }
                NSColor(white: 0.3, alpha: 1).setFill()
                for (x, width) in [(24.0, 0.18), (bounds.width * 0.25, 0.15), (bounds.width * 0.47, 0.12)] {
                    CGRect(x: x, y: y + 16, width: bounds.width * width, height: 10).fill()
                }
                CGRect(x: bounds.width * 0.72, y: y + 16, width: bounds.width * 0.1, height: 10).fill()
            }
        }
    }
}
