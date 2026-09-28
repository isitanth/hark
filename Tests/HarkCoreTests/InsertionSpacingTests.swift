import Foundation
import HarkCore
import Testing

struct SpacingCase: Sendable, CustomTestStringConvertible {
    let name: String
    /// The character the field reports before the caret; nil when it does not say.
    let previous: Character?
    let text: String
    let spaced: String

    var testDescription: String { name }
}

let spacingCases: [SpacingCase] = [
    // The case this exists for: two dictations in a row.
    .init(name: "after a full stop", previous: ".", text: "Next sentence.", spaced: " Next sentence."),
    .init(name: "after a letter", previous: "o", text: "there", spaced: " there"),
    .init(name: "after a capital", previous: "A", text: "bis", spaced: " bis"),
    .init(name: "after a digit", previous: "7", text: "euros", spaced: " euros"),
    .init(name: "after a comma", previous: ",", text: "puis", spaced: " puis"),
    .init(name: "after a question mark", previous: "?", text: "Oui", spaced: " Oui"),
    .init(name: "after a closing bracket", previous: ")", text: "and", spaced: " and"),
    .init(name: "after a per cent sign", previous: "%", text: "of them", spaced: " of them"),
    // Nothing to continue from.
    .init(name: "the field does not say", previous: nil, text: "Hello", spaced: "Hello"),
    .init(name: "the start of a field", previous: nil, text: "Hello", spaced: "Hello"),
    .init(name: "after a space", previous: " ", text: "Hello", spaced: "Hello"),
    .init(name: "after a line break", previous: "\n", text: "Hello", spaced: "Hello"),
    .init(name: "after a tab", previous: "\t", text: "Hello", spaced: "Hello"),
    .init(name: "after a no-break space", previous: "\u{00A0}", text: "Hello", spaced: "Hello"),
    // Openers, and the marks that join rather than close.
    .init(name: "after an opening bracket", previous: "(", text: "aside", spaced: "aside"),
    .init(name: "after an opening guillemet", previous: "«", text: "citation", spaced: "citation"),
    .init(name: "after a hyphen", previous: "-", text: "ish", spaced: "ish"),
    .init(name: "after a slash", previous: "/", text: "path", spaced: "path"),
    .init(name: "after an at sign", previous: "@", text: "example.com", spaced: "example.com"),
    .init(name: "after a straight quote, too ambiguous to guess", previous: "\"", text: "hello", spaced: "hello"),
    // The dictation brings its own spacing or punctuation.
    .init(name: "the text starts with a space", previous: ".", text: " already", spaced: " already"),
    .init(name: "the text starts with a line break", previous: ".", text: "\nnew line", spaced: "\nnew line"),
    .init(name: "the text starts with a comma", previous: "s", text: ", and then", spaced: ", and then"),
    .init(name: "the text starts with a full stop", previous: "s", text: ".", spaced: "."),
    .init(name: "the text starts with a closing guillemet", previous: "n", text: "» dit-il", spaced: "» dit-il"),
    .init(name: "nothing was said", previous: ".", text: "", spaced: ""),
    // French, where the letters and the punctuation are not ASCII.
    .init(name: "after an accented letter", previous: "é", text: "puis", spaced: " puis"),
    .init(name: "after a cedilla", previous: "ç", text: "a marché", spaced: " a marché"),
    .init(name: "after a closing guillemet", previous: "»", text: "dit-il", spaced: " dit-il"),
    .init(name: "after a French apostrophe", previous: "’", text: "ordinateur", spaced: "ordinateur"),
    .init(name: "after an ellipsis", previous: "…", text: "et puis", spaced: " et puis"),
    // A grapheme of more than one UTF-16 unit still reads as the letter it is.
    .init(name: "after a decomposed letter", previous: "ệ", text: "puis", spaced: " puis"),
    .init(name: "after a composed letter", previous: "\u{1EC7}", text: "puis", spaced: " puis"),
    // Not letters, not digits, not punctuation that closes.
    .init(name: "after an emoji", previous: "🇫🇷", text: "Bonjour", spaced: "Bonjour"),
    .init(name: "after a currency sign", previous: "€", text: "de plus", spaced: "de plus"),
]

@Suite struct InsertionSpacingTests {
    @Test(arguments: spacingCases)
    func spaced(_ c: SpacingCase) {
        #expect(InsertionSpacing.spaced(c.text, after: c.previous) == c.spaced)
        #expect(InsertionSpacing.needsSpace(after: c.previous, before: c.text) == (c.spaced != c.text))
    }

    /// A space is added, never anything else, and never more than one.
    @Test func theOnlyChangeIsOneLeadingSpace() {
        for c in spacingCases {
            #expect(c.spaced == c.text || c.spaced == " " + c.text, "\(c.name)")
        }
    }
}
