import Foundation
import HarkCore
import Testing

struct NormalizationCase: Sendable, CustomTestStringConvertible {
    let input: String
    let expected: String

    init(_ input: String, _ expected: String) {
        self.input = input
        self.expected = expected
    }

    var testDescription: String {
        let escaped = input.unicodeScalars.map { $0.isASCII ? String($0) : String(format: "U+%04X", $0.value) }
        return "\(escaped.joined()) -> \"\(expected)\""
    }
}

enum NormalizerCases {
    /// The strings the rest of M3 is written against: the default table's phrases as whisper types them.
    static let golden: [NormalizationCase] = [
        .init("Open Finder.", "open finder"),
        .init("open finder please", "open finder please"),
        .init("Ouvre le Finder", "ouvre le finder"),
        .init(" Ouvre le Finder. ", "ouvre le finder"),
        .init("Start the VPN!", "start the vpn"),
    ]

    /// Every letter French writes with a diacritic, paired with the base letter it has to fold to.
    static let frenchDiacritics: [(letter: String, base: String)] = [
        ("à", "a"), ("â", "a"), ("ä", "a"), ("ç", "c"), ("é", "e"), ("è", "e"), ("ê", "e"), ("ë", "e"),
        ("î", "i"), ("ï", "i"), ("ô", "o"), ("ö", "o"), ("ù", "u"), ("û", "u"), ("ü", "u"), ("ÿ", "y"),
    ]

    /// Each accented letter alone, lower and upper case, precomposed (NFC) and decomposed (NFD).
    static let accents: [NormalizationCase] = frenchDiacritics.flatMap { letter, base in
        [letter, letter.uppercased()].flatMap { form in
            [
                NormalizationCase(form.precomposedStringWithCanonicalMapping, base),
                NormalizationCase(form.decomposedStringWithCanonicalMapping, base),
            ]
        }
    }

    static let accentedWords: [NormalizationCase] = [
        .init("Écoute", "ecoute"),
        .init("Ça va", "ca va"),
        .init("Noël", "noel"),
        .init("Où est Août", "ou est aout"),
        .init("Maïs grillé", "mais grille"),
        .init("HÔTEL DE VILLE", "hotel de ville"),
        .init("L'Haÿ-les-Roses", "l hay les roses"),
        .init("ouvré", "ouvre"),
        // More than one mark on a letter, and a mark with no letter under it.
        .init("e\u{0301}\u{0302}t\u{0301}e\u{0301}", "ete"),
        .init("\u{0301}ouvre", "ouvre"),
    ]

    static let ligatures: [NormalizationCase] = [
        .init("œuvre", "oeuvre"),
        .init("Œuvre", "oeuvre"),
        .init("SŒUR", "soeur"),
        .init("Cœur", "coeur"),
        .init("æther", "aether"),
        .init("Æsop", "aesop"),
        .init("ex æquo", "ex aequo"),
        .init("Straße", "strasse"),
        .init("STRAẞE", "strasse"),
        .init("ǽ", "ae"),
        .init("ﬁnance", "finance"),
        .init("ﬂeur", "fleur"),
        .init("eﬀet", "effet"),
    ]

    static let punctuation: [NormalizationCase] = [
        .init("open finder.", "open finder"),
        .init("open finder!", "open finder"),
        .init("open finder?", "open finder"),
        .init("open, finder", "open finder"),
        .init("open.finder", "open finder"),
        .init("« ouvre le finder »", "ouvre le finder"),
        .init("“open finder”", "open finder"),
        .init("\"open finder\"", "open finder"),
        .init("ouvre le finder…", "ouvre le finder"),
        .init("ouvre le finder...", "ouvre le finder"),
        .init("ouvre ; le : finder", "ouvre le finder"),
        .init("ouvre;le:finder", "ouvre le finder"),
        .init("¿open finder? ¡ya!", "open finder ya"),
        .init("open/finder\\now", "open finder now"),
        .init("open_finder", "open finder"),
        .init("#open @finder & co", "open finder co"),
        .init("100% sûr", "100 sur"),
        .init("5 € + 3 $ = 8 £", "5 3 8"),
        .init("a·b", "a b"),
        // French typography: a narrow no-break space before ! ? : ; and a no-break space inside « ».
        .init("ouvre le finder\u{202F}!", "ouvre le finder"),
        .init("tu es là\u{202F}?", "tu es la"),
        .init("note\u{202F}: rappel", "note rappel"),
        .init("«\u{00A0}ouvre\u{00A0}»", "ouvre"),
    ]

    static let apostrophes: [NormalizationCase] = [
        .init("l'app", "l app"),
        .init("l’app", "l app"),
        .init("lʼapp", "l app"),
        .init("l‘app", "l app"),
        .init("L'APP", "l app"),
        .init("aujourd'hui", "aujourd hui"),
        .init("don't stop", "don t stop"),
        .init("'open finder'", "open finder"),
    ]

    static let dashes: [NormalizationCase] = [
        .init("peut-être", "peut etre"),
        .init("a-b", "a b"),
        .init("a‐b", "a b"),
        .init("a–b", "a b"),
        .init("a—b", "a b"),
        .init("a − b", "a b"),
        .init("- open finder -", "open finder"),
        .init("open -- finder", "open finder"),
    ]

    /// Whisper's own markup, removed by the rule `HallucinationFilter` applies to dictation.
    static let annotations: [NormalizationCase] = [
        .init("[BLANK_AUDIO]", ""),
        .init("[BLANK_AUDIO] open finder", "open finder"),
        .init("open finder [inaudible]", "open finder"),
        .init("(music) ouvre le finder", "ouvre le finder"),
        .init("(Musique) ouvre le finder", "ouvre le finder"),
        .init("*laughs* open finder", "open finder"),
        .init("open *rires* finder", "open finder"),
        .init("♪ la la la ♪ open finder", "open finder"),
        // Parentheses a person dictated are kept, as words.
        .init("open (the) finder", "open the finder"),
        .init("open *finder*", "open finder"),
        // An opener with no closer is literal text.
        .init("open (finder", "open finder"),
        .init("[open finder", "open finder"),
    ]

    static let emoji: [NormalizationCase] = [
        .init("open finder 👍", "open finder"),
        .init("👍🏽 ouvre le finder", "ouvre le finder"),
        .init("open👨‍👩‍👧finder", "open finder"),
        .init("🇫🇷 france", "france"),
        .init("open ❤️ finder", "open finder"),
        .init("tab 1️⃣", "tab 1"),
        .init("🎉🎉🎉", ""),
        .init("→ open ★ finder ©", "open finder"),
    ]

    static let whitespace: [NormalizationCase] = [
        .init("open\tfinder", "open finder"),
        .init("open\nfinder", "open finder"),
        .init("open\r\nfinder", "open finder"),
        .init("  open    finder  ", "open finder"),
        .init("\t open \n\n finder \t", "open finder"),
        .init("open\u{00A0}finder", "open finder"),
        .init("open\u{202F}finder", "open finder"),
        .init("open\u{2009}finder", "open finder"),
        .init("open\u{3000}finder", "open finder"),
        .init("open\u{200B}finder", "open finder"),
        .init("open\u{2028}finder", "open finder"),
    ]

    static let digits: [NormalizationCase] = [
        .init("open tab 3", "open tab 3"),
        .init("2024", "2024"),
        .init("version 2.5", "version 2 5"),
        .init("3,14", "3 14"),
        .init("1er étage", "1er etage"),
        .init("x²", "x2"),
        .init("１２３", "123"),
        .init("٣", "٣"),
        .init("½", "1 2"),
    ]

    static let empty: [NormalizationCase] = [
        .init("", ""),
        .init(" ", ""),
        .init("   ", ""),
        .init("\t\n\r\n", ""),
        .init("\u{00A0}\u{202F}", ""),
        .init("...", ""),
        .init("?!", ""),
        .init("« »", ""),
        .init("[BLANK_AUDIO]", ""),
        .init("(music)", ""),
        .init("👍", ""),
    ]

    /// Compatibility forms that NFKD folds, including those that decompose to capitals and so need the second
    /// lowercasing.
    static let compatibility: [NormalizationCase] = [
        .init("ＯＰＥＮ　ｆｉｎｄｅｒ", "open finder"),
        .init("ℌello", "hello"),
        .init("ℂ", "c"),
        .init("㎒", "mhz"),
        .init("ᴬᴮ", "ab"),
        .init("Ⅻ", "xii"),
        .init("İstanbul", "istanbul"),
        .init("ǅemal", "dzemal"),
        .init("𝐎𝐩𝐞𝐧", "open"),
    ]

    /// Scripts other than Latin keep their letters.
    static let otherScripts: [NormalizationCase] = [
        .init("Москва", "москва"),
        // Swift lowercases scalar by scalar, without the final-sigma rule: Σ becomes σ, never ς.
        .init("ΟΔΟΣ", "\u{03BF}\u{03B4}\u{03BF}\u{03C3}"),
        .init("東京 タワー", "東京 タワー"),
        .init("ラーメン", "ラーメン"),
    ]

    static let allTables: [[NormalizationCase]] = [
        golden, accents, accentedWords, ligatures, punctuation, apostrophes, dashes,
        annotations, emoji, whitespace, digits, empty, compatibility, otherScripts,
    ]

    /// Every scalar of the blocks where case, compatibility and diacritics interact: Latin, Greek, Cyrillic, phonetic
    /// extensions, letterlike symbols, number forms, CJK compatibility squares, presentation and full-width forms, and
    /// mathematical alphanumerics. Each sits between two letters, so a scalar that turns into a letter joins a word.
    static let sweep: [String] = [
        0x0000...0x052F, 0x1D00...0x1DBF, 0x1E00...0x1FFF, 0x2000...0x24FF, 0x3300...0x33FF, 0xFB00...0xFB4F,
        0xFF00...0xFFEF, 0x1D400...0x1D7FF,
    ]
    .flatMap { $0 }
    .compactMap { Unicode.Scalar(UInt32($0)) }
    .map { "A\(String($0))b" }
}

@Suite struct NormalizerTests {
    @Test(arguments: NormalizerCases.golden + NormalizerCases.accentedWords + NormalizerCases.ligatures)
    func foldsCaseDiacriticsAndLigatures(_ testCase: NormalizationCase) {
        #expect(Normalizer.normalize(testCase.input) == testCase.expected)
    }

    @Test(arguments: NormalizerCases.accents)
    func foldsEveryFrenchDiacriticInBothCasesAndForms(_ testCase: NormalizationCase) {
        #expect(Normalizer.normalize(testCase.input) == testCase.expected)
    }

    @Test(arguments: NormalizerCases.punctuation + NormalizerCases.apostrophes + NormalizerCases.dashes)
    func turnsPunctuationApostrophesAndDashesIntoSpaces(_ testCase: NormalizationCase) {
        #expect(Normalizer.normalize(testCase.input) == testCase.expected)
    }

    @Test(arguments: NormalizerCases.annotations)
    func removesWhisperAnnotations(_ testCase: NormalizationCase) {
        #expect(Normalizer.normalize(testCase.input) == testCase.expected)
    }

    @Test(arguments: NormalizerCases.emoji + NormalizerCases.whitespace + NormalizerCases.digits)
    func dropsEmojiCollapsesWhitespaceAndKeepsDigits(_ testCase: NormalizationCase) {
        #expect(Normalizer.normalize(testCase.input) == testCase.expected)
    }

    @Test(arguments: NormalizerCases.empty)
    func textWithNoWordsNormalizesToEmpty(_ testCase: NormalizationCase) {
        #expect(Normalizer.normalize(testCase.input) == testCase.expected)
    }

    @Test(arguments: NormalizerCases.compatibility + NormalizerCases.otherScripts)
    func foldsCompatibilityFormsAndKeepsOtherScripts(_ testCase: NormalizationCase) {
        #expect(Normalizer.normalize(testCase.input) == testCase.expected)
    }

    /// Swift's `==` on strings already ignores NFC versus NFD, so the comparison is on scalars.
    @Test(arguments: [
        "Ouvre le Finder", "Écoute", "Noël à l'hôtel", "Où est Août", "L'Haÿ-les-Roses", "ÇA VA", "Œuvre", "ǽ",
        "e\u{0301}\u{0302}",
    ])
    func precomposedAndDecomposedInputsGiveTheSameScalars(_ text: String) {
        let precomposed = text.precomposedStringWithCanonicalMapping
        let decomposed = text.decomposedStringWithCanonicalMapping
        let output = Normalizer.normalize(precomposed)
        #expect(Array(output.unicodeScalars) == Array(Normalizer.normalize(decomposed).unicodeScalars))
        #expect(output.unicodeScalars.allSatisfy { $0.properties.generalCategory != .nonspacingMark })
    }

    @Test func outputIsOnlyLowercaseWordsSeparatedBySingleSpaces() {
        for input in NormalizerCases.allTables.flatMap({ $0.map(\.input) }) + NormalizerCases.sweep {
            let output = Normalizer.normalize(input)
            #expect(!output.hasPrefix(" ") && !output.hasSuffix(" ") && !output.contains("  "), "\(input)")
            #expect(output == output.lowercased(), "\(input)")
        }
    }

    @Test(arguments: NormalizerCases.allTables)
    func isIdempotentOverEveryTable(_ table: [NormalizationCase]) {
        for testCase in table {
            let once = Normalizer.normalize(testCase.input)
            #expect(Array(Normalizer.normalize(once).unicodeScalars) == Array(once.unicodeScalars), "\(testCase)")
        }
    }

    /// Lowercasing only before NFKD fails this for 656 scalars, such as ℌ, ᴬ and ㎒, which decompose to capitals.
    @Test func isIdempotentOverTheCompatibilitySweep() {
        for input in NormalizerCases.sweep {
            let once = Normalizer.normalize(input)
            #expect(Array(Normalizer.normalize(once).unicodeScalars) == Array(once.unicodeScalars), "\(input)")
        }
    }
}
