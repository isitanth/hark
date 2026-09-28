import Foundation

/// The canonical text of a `CommandConfig`, the one the Settings UI writes.
///
/// Every string is double-quoted with JSON's escapes, which YAML reads the same way, so no phrase or target can be
/// mistaken for a number, a boolean, a comment or a key. Numbers are written in their shortest form.
enum CommandConfigEmitter {
    static func yaml(for config: CommandConfig) -> String {
        var lines = [
            "version: \(CommandConfig.supportedVersion)", "", "defaults:",
            "  threshold: \(number(config.defaults.threshold))",
        ]

        if !config.apps.isEmpty {
            lines += ["", "apps:"]
            for id in config.apps.keys.sorted() {
                lines += ["  \(quoted(id)):", "    insert: \(config.apps[id]?.insert.rawValue ?? "")"]
            }
        }
        for (key, lists) in [("open_verbs", config.openVerbs), ("fillers", config.fillers)] where !lists.isEmpty {
            lines += ["", "\(key):"]
            for language in lists.keys.sorted() {
                lines.append("  \(quoted(language)): \(list(lists[language] ?? []))")
            }
        }

        lines.append("")
        guard !config.commands.isEmpty else { return (lines + ["commands: []", ""]).joined(separator: "\n") }
        lines.append("commands:")
        for (index, command) in config.commands.enumerated() {
            if index > 0 {
                lines.append("")
            }
            lines += [
                "  - id: \(quoted(command.id))", "    action: \(command.action.rawValue)",
                "    app: \(quoted(command.app))",
            ]
            if !command.aliases.isEmpty {
                lines.append("    aliases: \(list(command.aliases))")
            }
        }
        return (lines + [""]).joined(separator: "\n")
    }

    /// A flow list of quoted strings: `["open", "launch"]`.
    private static func list(_ items: [String]) -> String {
        "[" + items.map(quoted).joined(separator: ", ") + "]"
    }

    /// A JSON string literal, which is also a valid YAML double-quoted scalar. Beyond what JSON requires, it escapes
    /// what YAML would not read back as written: DEL and the C1 controls, NEL and the Unicode line and paragraph
    /// separators (all line breaks to YAML 1.1), the BOM, and the two noncharacters libyaml refuses.
    static func quoted(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                switch scalar.value {
                case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029, 0xFEFF, 0xFFFE, 0xFFFF:
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                default:
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }

    /// Swift's shortest round-tripping form, without the `.0` of a whole number: 0.85, 1, 1e-05.
    static func number(_ value: Double) -> String {
        let text = value.description
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
