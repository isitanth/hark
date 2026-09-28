import Foundation
import Yams

/// Bytes to a composed YAML document, then to `CommandConfig`. Everything that is not the schema lives here: the size
/// cap, the BOM, strict UTF-8, line endings, and the translation of libyaml's errors.
enum CommandConfigParser {
    static func parse(_ data: Data) throws(ConfigError) -> CommandConfig {
        let text = try decode(data)
        let parser: Parser
        let root: Node?
        do {
            parser = try Parser(yaml: text, encoding: .utf8)
            root = try parser.singleRoot()
        } catch let error as YamlError {
            throw configError(from: error)
        } catch {
            throw ConfigError(.syntax(String(describing: error)))
        }
        // Yams holds each node's anchor weakly and the parser owns the anchors: once the parser is gone, every anchor
        // reads nil and the walker could no longer refuse them.
        defer { withExtendedLifetime(parser) {} }
        guard let root, !ConfigNodes.isNull(root) else { throw ConfigError(.empty) }
        return try CommandConfigSchema.read(root)
    }

    /// Size, BOM, strict UTF-8, CRLF and lone CR to LF, then the characters libyaml's reader refuses.
    ///
    /// libyaml counts CRLF and CR as one line break each, so the rewrite leaves every line and column where it was;
    /// it only means nothing downstream has to know about CR. The character check duplicates libyaml's reader on
    /// purpose: the reader reports a byte offset with no line, and it reads ahead, so its error would not point at the
    /// character.
    static func decode(_ data: Data) throws(ConfigError) -> String {
        guard data.count <= CommandConfig.maximumFileSize else { throw ConfigError(.tooLarge(bytes: data.count)) }
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        let decoded = String(decoding: bytes, as: UTF8.self)
        guard decoded.utf8.elementsEqual(bytes) else { throw ConfigError(.notUTF8) }

        var text = String.UnicodeScalarView()
        var line = 1
        var column = 1
        var previousWasCR = false
        for scalar in decoded.unicodeScalars {
            defer { previousWasCR = scalar == "\r" }
            if scalar == "\n" && previousWasCR {
                continue
            }
            guard isReadable(scalar) else {
                throw ConfigError(.syntax("control characters are not allowed"), at: .init(line: line, column: column))
            }
            let normalized: Unicode.Scalar = scalar == "\r" ? "\n" : scalar
            text.append(normalized)
            if isLineBreak(normalized) {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return String(text)
    }

    /// libyaml's reader: tab, line feed, carriage return, NEL, and printable text outside the surrogates, U+FFFE and
    /// U+FFFF.
    private static func isReadable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D, 0x20...0x7E, 0x85, 0xA0...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: true
        default: false
        }
    }

    /// The breaks libyaml counts as a new line once CR is gone: LF, NEL, and the Unicode line and paragraph separators.
    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\u{85}" || scalar == "\u{2028}" || scalar == "\u{2029}"
    }

    private static func configError(from error: YamlError) -> ConfigError {
        switch error {
        case .scanner(let context, let problem, let mark, _),
            .parser(let context, let problem, let mark, _),
            .composer(let context, let problem, let mark, _):
            let detail = context.map { "\(problem) (\($0.text) at \(ConfigNodes.location($0.mark)))" } ?? problem
            return ConfigError(.syntax(detail), at: ConfigNodes.location(mark))
        case .duplicatedKeysInMapping(let duplicates, let context):
            // Yams reports where the key first appears, not the mapping that holds it, so the path stays empty.
            return ConfigError(.duplicateKey(duplicates.first ?? "", path: ""), at: ConfigNodes.location(context.mark))
        case .reader(let problem, _, _, _):
            // `decode` already refused what the reader refuses; this is the backstop.
            return ConfigError(problem.localizedCaseInsensitiveContains("utf") ? .notUTF8 : .syntax(problem))
        default:
            return ConfigError(.syntax(error.description))
        }
    }
}
