/// Why the anchored layer shows no cells, or not all of them, for the Ask panel's one line (M14, plan §4.5; a contract
/// amendment after M14.0 B, 2026-11-05). nil when the cells show in full or nothing is asked. The layer (M14.5)
/// decides; the panel (S4) says it, in English and French.
public enum LayerNote: Sendable, Equatable {
    /// No window to draw on: the desktop, a zone split between windows, or a window at the floating level or above,
    /// such as Quick Look's panel (M14.0 B1). The panel's rows list the cells instead.
    case noWindow
    /// The zone was not found again with certainty: it moved out of reach, or two look-alike places passed (M14.0 B3).
    /// Show Cells tries once more.
    case notFound
    /// Some tinted cells are out of view: `visible` of `total` show.
    case outOfView(visible: Int, total: Int)
    /// The framed window closed: no cells for the rest of the conversation.
    case windowClosed
    /// The window went to a display of another backing scale: no cells for the rest of the turn.
    case otherScale
}
