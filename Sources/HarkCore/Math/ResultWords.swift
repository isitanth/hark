import Foundation

// The words that name a result (M14, plan §4.2), beside `SpokenNumbers`: `wordcheck_m14.py`'s `RESULT_WORDS`, over the
// text as said rather than normalized, so that its phrases can be taken out of it.

/// « résultat un », "result 2", « le deuxième résultat », "the last result", ①…⑳. Two uses: its phrases are taken out
/// before the spoken-constant check, and a follow-up that names a result goes to the exact path past the frozen word
/// check, its block list still winning. `MathIntent`'s frozen lists are not touched.
public enum ResultWords {
    /// The result numbers `text` names, in order; `count` is how many the conversation holds ("the last" names it).
    public static func named(in text: String, count: Int) -> [Int] {
        phrases(in: text.precomposedStringWithCanonicalMapping).compactMap { phrase in
            switch phrase.name {
            case .number(let number): number
            case .last: count > 0 ? count : nil
            }
        }
    }

    /// `text` with each phrase that names a result replaced by a space.
    public static func stripped(_ text: String) -> String {
        let composed = text.precomposedStringWithCanonicalMapping
        var out = composed as NSString
        for phrase in phrases(in: composed).reversed() {
            out = out.replacingCharacters(in: phrase.range, with: " ") as NSString
        }
        return out as String
    }

    enum Name: Equatable {
        case number(Int)
        case last
    }

    static let numbers: [String: Int] = [
        "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "sept": 7, "huit": 8, "neuf": 9,
        "dix": 10, "onze": 11, "douze": 12, "treize": 13, "quatorze": 14, "quinze": 15, "seize": 16, "dix sept": 17,
        "dix huit": 18, "dix neuf": 19, "vingt": 20, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
    ]

    static let ordinals: [String: Name] = [
        "premier": .number(1), "premiere": .number(1), "second": .number(2), "seconde": .number(2),
        "deuxieme": .number(2), "troisieme": .number(3), "quatrieme": .number(4), "cinquieme": .number(5),
        "sixieme": .number(6), "dernier": .last, "derniere": .last, "first": .number(1), "third": .number(3),
        "fourth": .number(4), "fifth": .number(5), "sixth": .number(6), "last": .last,
    ]

    static let circled = Array("①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳")

    /// A word's letters as `MathIntent.normalize` leaves them: no accent, lowercased, separators one space.
    static func plain(_ text: String) -> String {
        MathIntent.normalize(text).trimmingCharacters(in: .whitespaces)
    }

    /// « résultat » or "result", optionally « numéro », « n° », "number", "no", then 1 to 20 in digits or words; or an
    /// ordinal before « résultat » or "result". Whole words, any case, any separator but `%` between them.
    static let pattern: NSRegularExpression? = {
        let edge = #"(?<![\p{L}\p{N}])"#
        let end = #"(?![\p{L}\p{N}])"#
        let gap = #"[^\p{L}\p{N}%]+"#
        let result = "(?:r[eé]sultat|result)"
        let words = numbers.keys.sorted { $0.count > $1.count }.map {
            $0.replacingOccurrences(of: " ", with: gap)
        }
        let number = "(?:20|1[0-9]|[1-9]|" + words.joined(separator: "|") + ")"
        let ordinal =
            "(?:premier|premi[eè]re|seconde|second|deuxi[eè]me|troisi[eè]me|quatri[eè]me|cinqui[eè]me|sixi[eè]me"
            + "|derni[eè]re|dernier|first|third|fourth|fifth|sixth|last)"
        let marker = "(?:" + gap + "(?:num[eé]ro|number|no|n)" + end + ")?"
        let named = edge + result + marker + gap + "(?<number>" + number + ")" + end
        let ordered = edge + "(?<ordinal>" + ordinal + ")" + gap + result + end
        return try? NSRegularExpression(pattern: named + "|" + ordered, options: [.caseInsensitive])
    }()

    /// Every phrase that names a result, in text order, with its range in `text` (UTF-16) and the result it names.
    static func phrases(in text: String) -> [(range: NSRange, name: Name)] {
        let source = text as NSString
        var found: [(range: NSRange, name: Name)] = []
        let matches = pattern?.matches(in: text, range: NSRange(location: 0, length: source.length)) ?? []
        for match in matches {
            let numberRange = match.range(withName: "number")
            if numberRange.location != NSNotFound {
                let spoken = plain(source.substring(with: numberRange))
                if let value = Int(spoken) ?? numbers[spoken] { found.append((match.range, .number(value))) }
            } else {
                let ordinalRange = match.range(withName: "ordinal")
                guard ordinalRange.location != NSNotFound,
                    let name = ordinals[plain(source.substring(with: ordinalRange))]
                else { continue }
                found.append((match.range, name))
            }
        }
        var location = 0
        for character in text {
            let length = String(character).utf16.count
            if let index = circled.firstIndex(of: character) {
                found.append((NSRange(location: location, length: length), .number(index + 1)))
            }
            location += length
        }
        return found.sorted { $0.range.location < $1.range.location }
    }
}
