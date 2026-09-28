import Testing

@testable import HarkCore

struct DisplayLanguageTests {
    @Test(
        arguments: [
            (nil, DisplayLanguage.system),
            ([], .system),
            (["en"], .english),
            (["en-US"], .english),
            (["en-GB", "fr"], .english),
            (["fr"], .french),
            (["fr-FR"], .french),
            (["fr-CA", "en"], .french),
            (["de"], .system),
            (["de-DE", "en"], .system),
            ([""], .system),
        ] as [([String]?, DisplayLanguage)])
    func readsTheFirstLanguage(appleLanguages: [String]?, expected: DisplayLanguage) {
        #expect(DisplayLanguage(appleLanguages: appleLanguages) == expected)
    }

    @Test(
        arguments: [
            (DisplayLanguage.system, nil),
            (.english, ["en"]),
            (.french, ["fr"]),
        ] as [(DisplayLanguage, [String]?)])
    func writesOneLanguageOrNone(language: DisplayLanguage, expected: [String]?) {
        #expect(language.appleLanguages == expected)
    }

    @Test(arguments: DisplayLanguage.allCases)
    func roundTrips(language: DisplayLanguage) {
        #expect(DisplayLanguage(appleLanguages: language.appleLanguages) == language)
    }

    @Test func storesUnderTheSystemKey() {
        #expect(DisplayLanguage.defaultsKey == "AppleLanguages")
    }
}
