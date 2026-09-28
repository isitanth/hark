import Foundation

/// Jaro-Winkler similarity in [0, 1], compared by `Character`: 1 for identical strings, 0 when nothing matches.
///
/// Jaro counts the characters that match within half the longer length, less one, and the transpositions among them;
/// Winkler adds `prefixScale` of the remaining distance for each character of common prefix, up to `maximumPrefix`.
public enum JaroWinkler {
    public static let prefixScale = 0.1
    public static let maximumPrefix = 4

    @Sendable public static func similarity(_ a: String, _ b: String) -> Double {
        let s = Array(a)
        let t = Array(b)
        if s.isEmpty && t.isEmpty { return 1 }
        guard !s.isEmpty, !t.isEmpty else { return 0 }

        let window = max(0, max(s.count, t.count) / 2 - 1)
        var sMatched = [Bool](repeating: false, count: s.count)
        var tMatched = [Bool](repeating: false, count: t.count)
        var matches = 0
        for i in s.indices {
            let low = max(0, i - window)
            let high = min(t.count - 1, i + window)
            guard low <= high else { continue }
            for j in low...high where !tMatched[j] && s[i] == t[j] {
                sMatched[i] = true
                tMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }

        var halfTranspositions = 0
        var j = 0
        for i in s.indices where sMatched[i] {
            while !tMatched[j] { j += 1 }
            if s[i] != t[j] { halfTranspositions += 1 }
            j += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(s.count) + m / Double(t.count) + (m - Double(halfTranspositions) / 2) / m) / 3
        let prefix = zip(s, t).prefix(maximumPrefix).prefix { $0 == $1 }.count
        return jaro + Double(prefix) * prefixScale * (1 - jaro)
    }
}
