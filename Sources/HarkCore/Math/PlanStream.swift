import Foundation

// The partial plan, while it streams (M13, plan §4.3): `IntentSplit`'s twin.

public enum PlanStream {
    /// Each result's `understood` reached so far in a `{"results": [...]}` reply (M14, c2a §4.2), unescaped, the last
    /// one possibly cut, at most `PlanSet.maxResults`. Today's flat object gives its one. Nothing of a formula, a unit or
    /// a label is ever returned.
    public static func understoods(partial: String) -> [String] {
        var scanner = PartialJSON(Array(partial.unicodeScalars))
        scanner.skipPreamble()
        guard scanner.take("{") else { return [] }
        while true {
            scanner.skipSpace()
            guard case .complete(let key) = scanner.string() else { return [] }
            scanner.skipSpace()
            guard scanner.take(":") else { return [] }
            scanner.skipSpace()
            switch key {
            case "results":
                return results(&scanner)
            case "understood":
                switch scanner.string() {
                case .complete(let value), .partial(let value): return [value]
                case .absent: return []
                }
            default:
                guard scanner.skipValue() else { return [] }
            }
            scanner.skipSpace()
            guard scanner.take(",") else { return [] }
        }
    }

    /// The array's items as far as they go, each `understood` once reached; a cut stops the walk.
    private static func results(_ scanner: inout PartialJSON) -> [String] {
        var found: [String] = []
        guard scanner.take("[") else { return found }
        while found.count < PlanSet.maxResults {
            scanner.skipSpace()
            guard scanner.take("{") else { return found }
            var closed = false
            while !closed {
                scanner.skipSpace()
                if scanner.take("}") { break }
                guard case .complete(let key) = scanner.string() else { return found }
                scanner.skipSpace()
                guard scanner.take(":") else { return found }
                scanner.skipSpace()
                if key == "understood" {
                    switch scanner.string() {
                    case .complete(let value): found.append(value)
                    case .partial(let value):
                        found.append(value)
                        return found
                    case .absent: return found
                    }
                } else {
                    guard scanner.skipValue() else { return found }
                }
                scanner.skipSpace()
                if scanner.take("}") {
                    closed = true
                } else if !scanner.take(",") {
                    return found
                }
            }
            scanner.skipSpace()
            guard scanner.take(",") else { return found }
        }
        return found
    }
}

/// A cursor over a JSON text that may stop anywhere.
struct PartialJSON {
    enum Text {
        case complete(String)
        /// Cut before its closing quote: what decodes so far.
        case partial(String)
        case absent
    }

    let scalars: [Unicode.Scalar]
    var position = 0

    init(_ scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    var current: Unicode.Scalar? { position < scalars.count ? scalars[position] : nil }

    mutating func take(_ scalar: Unicode.Scalar) -> Bool {
        guard current == scalar else { return false }
        position += 1
        return true
    }

    mutating func skipSpace() {
        while let scalar = current, scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
            position += 1
        }
    }

    /// A BOM, whitespace and one opening code fence.
    mutating func skipPreamble() {
        _ = take("\u{FEFF}")
        skipSpace()
        if take("`"), take("`"), take("`") {
            while let scalar = current, scalar.properties.isAlphabetic { position += 1 }
        }
        skipSpace()
    }

    func hex(at start: Int) -> UInt32? {
        guard start + 4 <= scalars.count else { return nil }
        return UInt32(String(String.UnicodeScalarView(scalars[start..<(start + 4)])), radix: 16)
    }

    /// A string at the cursor, its escapes decoded.
    mutating func string() -> Text {
        guard take("\"") else { return .absent }
        var out = String.UnicodeScalarView()
        while let scalar = current {
            if scalar == "\"" {
                position += 1
                return .complete(String(out))
            }
            guard scalar == "\\" else {
                out.append(scalar)
                position += 1
                continue
            }
            guard position + 1 < scalars.count else { return .partial(String(out)) }
            let escape = scalars[position + 1]
            switch escape {
            case "\"", "\\", "/":
                out.append(escape)
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "u":
                guard let unit = hex(at: position + 2) else { return .partial(String(out)) }
                if (0xD800...0xDBFF).contains(unit) {
                    guard position + 12 <= scalars.count else { return .partial(String(out)) }
                    guard scalars[position + 6] == "\\", scalars[position + 7] == "u",
                        let low = hex(at: position + 8), (0xDC00...0xDFFF).contains(low),
                        let pair = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                    else { return .partial(String(out)) }
                    out.append(pair)
                    position += 12
                    continue
                }
                if let decoded = Unicode.Scalar(unit) { out.append(decoded) }
                position += 6
                continue
            default:
                return .partial(String(out))
            }
            position += 2
        }
        return .partial(String(out))
    }

    /// Any value: a whole string, or a number, literal, object or array up to its end. False when cut.
    mutating func skipValue() -> Bool {
        if current == "\"" {
            guard case .complete = string() else { return false }
            return true
        }
        var depth = 0
        while let scalar = current {
            switch scalar {
            case "\"":
                guard case .complete = string() else { return false }
                continue
            case "{", "[":
                depth += 1
            case "}", "]":
                if depth == 0 { return true }
                depth -= 1
            case ",":
                if depth == 0 { return true }
            default:
                break
            }
            position += 1
        }
        return false
    }
}
