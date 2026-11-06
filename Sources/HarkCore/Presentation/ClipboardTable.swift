import Foundation

/// The one-column table Copy puts on the clipboard beside the text when it takes several figures (0.2.1). Numbers reads
/// several lines of text as delimited data and takes a French figure's decimal comma for a column separator, even with
/// a tab after each line, but pastes an HTML table one figure per row; TextEdit, Notes and Mail then paste a table,
/// while Claude, Dia and Excel paste what they did (measured 2026-11-06, the user's choice).
public enum ClipboardTable {
    /// UTF-8 HTML, one row per figure in order, each figure as shown with its markup characters escaped (its no-break
    /// and narrow no-break spaces stay characters). Nil for fewer than two: one figure is a single line, which every app
    /// pastes whole.
    public static func html(_ figures: [String]) -> String? {
        guard figures.count > 1 else { return nil }
        let rows = figures.map { "<tr><td>\(escaped($0))</td></tr>" }.joined()
        return #"<html><head><meta charset="utf-8"></head><body><table>"# + rows + "</table></body></html>"
    }

    /// The characters HTML would read as markup in a cell; everything else is text there, as written.
    private static func escaped(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
