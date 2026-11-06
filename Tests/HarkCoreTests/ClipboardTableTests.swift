import Foundation
import HarkCore
import Testing

/// The table Copy puts beside several figures (0.2.1), in the shape measured on 2026-11-06: Numbers pastes it one
/// figure per row where it split the lines of text at a French decimal comma.
@Suite struct ClipboardTableTests {
    private static let head = #"<html><head><meta charset="utf-8"></head><body><table>"#
    private static let tail = "</table></body></html>"

    private static func table(_ cells: [String]) -> String {
        head + cells.map { "<tr><td>\($0)</td></tr>" }.joined() + tail
    }

    @Test func noFigureOrOneHasNoTable() {
        #expect(ClipboardTable.html([]) == nil)
        #expect(ClipboardTable.html(["89,67\u{00A0}€"]) == nil)
    }

    @Test func frenchFiguresKeepTheirSpacesAsCharacters() throws {
        let figures = ["89,67\u{00A0}€", "1\u{202F}076,04\u{00A0}€"]
        let html = try #require(ClipboardTable.html(figures))
        #expect(html == Self.table(figures))
        // The no-break spaces are UTF-8 bytes under the declared charset, never entities: the figure reads as shown.
        #expect(Data(html.utf8).range(of: Data([0xC2, 0xA0])) != nil)
        #expect(Data(html.utf8).range(of: Data([0xE2, 0x80, 0xAF])) != nil)
        #expect(!html.contains("&nbsp;") && !html.contains("&#"))
    }

    @Test func englishFiguresUnitLabelsAndThreeRowsInOrder() {
        let figures = ["$1,234.50", "38 To", "12"]
        #expect(ClipboardTable.html(figures) == Self.table(figures))
    }

    @Test func markupCharactersAreEscapedAndTheRestIsNot() {
        #expect(
            ClipboardTable.html(["R&D <1>", "\"x\" 'y' é"])
                == Self.table(["R&amp;D &lt;1&gt;", "&quot;x&quot; 'y' é"]))
    }

    @Test func theTableIsOneColumnWithOneRowPerFigure() throws {
        let html = try #require(ClipboardTable.html(["1", "2", "3"]))
        #expect(html.components(separatedBy: "<tr>").count - 1 == 3)
        #expect(html.components(separatedBy: "<td>").count - 1 == 3)
        #expect(!html.contains("\n") && !html.contains("\t"))
    }
}
