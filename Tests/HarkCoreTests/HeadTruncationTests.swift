import HarkCore
import Testing

@Suite("HeadTruncation")
struct HeadTruncationTests {
    static let coder = "\u{1F469}\u{200D}\u{1F4BB}"
    static let accented = String(repeating: "e\u{0301}", count: 15)

    static let table: [String] = [
        "",
        "  ",
        "bonjour",
        "exactly12chr",
        "one two three four",
        "one  two\nthree   four",
        "supercalifragilistic",
        "a b c d e f g h i j k l m",
        "Il a dit\u{00A0}: oui merci",
        accented,
        Array(repeating: coder, count: 20).joined(separator: " "),
        String(repeating: coder, count: 20),
    ]

    @Test(arguments: [
        ("", ""),
        ("  ", ""),
        ("bonjour", "bonjour"),
        ("exactly12chr", "exactly12chr"),
        ("one two three four", "\u{2026} three four"),
        ("one  two\nthree   four", "\u{2026} three four"),
        ("supercalifragilistic", "\u{2026}fragilistic"),
        ("Il a dit\u{00A0}: oui merci", "\u{2026} oui merci"),
        ("a b c d e f g h i j k l m", "\u{2026} i j k l m"),
    ])
    func exactStrings(input: String, expected: String) {
        #expect(HeadTruncation.fit(input, maxCharacters: 12) == expected)
    }

    @Test func dropsHeadAtFullBudget() {
        #expect(HeadTruncation.fit("one two three four", maxCharacters: 12).count == 12)
    }

    @Test func singleLettersKeepTheNewest() {
        let result = HeadTruncation.fit("a b c d e f g h i j k l m", maxCharacters: 12)
        #expect(result.count <= 12)
        #expect(result.hasPrefix("\u{2026}"))
        #expect(result.hasSuffix("m"))
    }

    @Test func narrowSpaceBindsPunctuationToItsWord() {
        let result = HeadTruncation.fit("Il a dit\u{00A0}: oui merci", maxCharacters: 12)
        #expect(!result.hasPrefix("\u{2026} :"))
        #expect(!result.dropFirst(2).hasPrefix("\u{00A0}"))
        let narrow = HeadTruncation.fit("Il a dit\u{202F}: oui merci", maxCharacters: 12)
        #expect(narrow == "\u{2026} oui merci")
    }

    @Test func combiningMarksStayAttached() {
        let result = HeadTruncation.fit(Self.accented, maxCharacters: 12)
        #expect(result.count <= 12)
        #expect(result.allSatisfy { $0.unicodeScalars.first != "\u{0301}" })
        #expect(result.dropFirst().allSatisfy { $0 == "e\u{0301}" })
    }

    @Test(arguments: [" ", ""])
    func zwjSequencesStayWhole(separator: String) {
        let input = Array(repeating: Self.coder, count: 20).joined(separator: separator)
        let result = HeadTruncation.fit(input, maxCharacters: 12)
        #expect(result.count <= 12)
        #expect(result.hasPrefix("\u{2026}"))
        #expect(result.allSatisfy { String($0) == Self.coder || $0 == "\u{2026}" || $0 == " " })
    }

    @Test(arguments: table)
    func tinyBudgetsReturnNothing(input: String) {
        #expect(HeadTruncation.fit(input, maxCharacters: 1) == "")
        #expect(HeadTruncation.fit(input, maxCharacters: 0) == "")
    }

    @Test(arguments: table)
    func fitsAndIsIdempotent(input: String) {
        for budget in [2, 3, 5, 12, 44] {
            let once = HeadTruncation.fit(input, maxCharacters: budget)
            #expect(once.count <= budget)
            #expect(HeadTruncation.fit(once, maxCharacters: budget) == once)
        }
    }
}
