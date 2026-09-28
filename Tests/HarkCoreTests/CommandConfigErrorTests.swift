import Foundation
import HarkCore
import Testing

/// A commands.yaml that has to fail with exactly `problem` at exactly `line` and `column`.
struct ConfigErrorCase: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    let problem: ConfigProblem
    let location: ConfigLocation?

    /// `lines` are joined with LF and end with one, so a case reads as the file does and line N is `lines[N - 1]`.
    init(_ name: String, _ lines: [String], _ problem: ConfigProblem, _ line: Int? = nil, _ column: Int? = nil) {
        self.name = name
        self.text = lines.map { $0 + "\n" }.joined()
        self.problem = problem
        self.location = line.map { ConfigLocation(line: $0, column: column ?? 1) }
    }

    var testDescription: String { name }

    /// The lines of a command whose own lines start at `line`, for tables that only vary one field.
    static func command(_ fields: [String]) -> [String] {
        ["version: 2", "commands:"] + fields.enumerated().map { index, field in (index == 0 ? "  - " : "    ") + field }
    }
}

enum ConfigErrorCases {
    static let actions = ActionType.allCases.map(\.rawValue)

    /// libyaml's own messages, with the context it gives. Checked against libyaml before being written down.
    static let syntax: [ConfigErrorCase] = [
        .init(
            "tab indentation", ["version: 2", "defaults:", "\tthreshold: 0.5"],
            .syntax(
                "found character that cannot start any token (while scanning for the next token at line 3, column 1)"),
            3, 1),
        .init(
            "unclosed quote", ["version: 2", "commands:", "  - id: \"open"],
            .syntax("found unexpected end of stream (while scanning a quoted scalar at line 3, column 9)"), 4, 1),
        .init(
            "value after a value", ["version: 2", "commands:", "  - id: open: finder"],
            .syntax("mapping values are not allowed in this context"), 3, 13),
        .init(
            "bad indentation", ["version: 2", "defaults:", "  threshold: 0.5", " x: 1"],
            .syntax("did not find expected key (while parsing a block mapping at line 1, column 1)"), 4, 2),
        .init(
            "unclosed flow list", ["version: 2", "commands: [", "  x"],
            .syntax("did not find expected ',' or ']' (while parsing a flow sequence at line 2, column 11)"), 4, 1),
        .init(
            "two documents", ["version: 2", "---", "version: 2"],
            .syntax("but found another document (expected a single document in the stream at line 1, column 1)"), 2, 1),
        .init("undefined alias", ["version: 2", "commands: *nope"], .syntax("found undefined alias"), 2, 11),
        .init(
            "NUL", ["version: 2", "commands:", "  - id: a\u{0}b"],
            .syntax("control characters are not allowed"), 3, 10),
        .init(
            "DEL after a combining accent", ["version: 2", "commands:", "  - id: e\u{301}\u{7F}"],
            .syntax("control characters are not allowed"), 3, 11),
        .init("U+FFFE", ["version: 2", "x: \u{FFFE}"], .syntax("control characters are not allowed"), 2, 4),
        .init(
            "control character after a NEL", ["version: 2", "x: a\u{85}\u{1B}"],
            .syntax("control characters are not allowed"), 3, 1),
    ]

    static let structure: [ConfigErrorCase] = [
        .init("anchor on a mapping", ["version: 2", "defaults: &d", "  threshold: 0.5"], .anchorsNotSupported, 2, 11),
        .init(
            "anchor before its alias",
            ConfigErrorCase.command(["id: &p a", "action: open_app", "app: x"])
                + ["  - id: *p", "    action: open_app", "    app: y"],
            .anchorsNotSupported, 3, 9),
        .init("anchor on a key", ["version: 2", "&k defaults:", "  threshold: 0.5"], .anchorsNotSupported, 2, 1),
        .init("anchor on the root", ["&root", "version: 2"], .anchorsNotSupported, 1, 1),
        .init(
            "duplicate key", ["version: 2", "defaults:", "  threshold: 0.5", "  threshold: 0.6"],
            .duplicateKey("threshold", path: ""), 3, 3),
        .init(
            "duplicate key under another tag", ["version: 2", "defaults:", "  threshold: 0.5", "  !x threshold: 0.6"],
            .duplicateKey("threshold", path: "defaults"), 4, 3),
        .init(
            "duplicate language under another tag", ["version: 2", "open_verbs:", "  en: [open]", "  !x en: [launch]"],
            .duplicateKey("en", path: "open_verbs"), 4, 3),
        .init(
            "duplicate bundle ID in another case",
            [
                "version: 2", "apps:", "  com.apple.Mail:", "    insert: paste", "  com.apple.mail:",
                "    insert: paste",
            ],
            .duplicateKey("com.apple.mail", path: "apps"), 5, 3),
        .init("list at the top", ["- version: 2"], .wrongType(path: "", expected: .mapping), 1, 1),
        .init("text at the top", ["hello"], .wrongType(path: "", expected: .mapping), 1, 1),
        .init("version as a list", ["version: [2]"], .wrongType(path: "version", expected: .number), 1, 10),
        .init(
            "defaults as a list", ["version: 2", "defaults: [a]"], .wrongType(path: "defaults", expected: .mapping), 2,
            11),
        .init("apps as text", ["version: 2", "apps: mail"], .wrongType(path: "apps", expected: .mapping), 2, 7),
        .init(
            "app without a value", ["version: 2", "apps:", "  com.apple.mail:"],
            .wrongType(path: "apps.com.apple.mail", expected: .mapping), 3, 18),
        .init(
            "app as text", ["version: 2", "apps:", "  com.apple.mail: paste"],
            .wrongType(path: "apps.com.apple.mail", expected: .mapping), 3, 19),
        .init(
            "open_verbs as a list", ["version: 2", "open_verbs: [open]"],
            .wrongType(path: "open_verbs", expected: .mapping), 2, 13),
        .init(
            "a language's verbs as text", ["version: 2", "open_verbs:", "  en: open"],
            .wrongType(path: "open_verbs.en", expected: .list), 3, 7),
        .init(
            "verb as a mapping", ["version: 2", "open_verbs:", "  en: [open, {a: b}]"],
            .wrongType(path: "open_verbs.en[1]", expected: .text), 3, 14),
        .init(
            "fillers as text", ["version: 2", "fillers: the"], .wrongType(path: "fillers", expected: .mapping), 2, 10),
        .init(
            "commands as a mapping", ["version: 2", "commands:", "  id: x"],
            .wrongType(path: "commands", expected: .list), 3, 3),
        .init(
            "command as text", ["version: 2", "commands:", "  - open finder"],
            .wrongType(path: "commands[0]", expected: .mapping), 3, 5),
        .init(
            "command left empty", ["version: 2", "commands:", "  -"],
            .wrongType(path: "commands[0]", expected: .mapping), 3, 4),
        .init(
            "id as a list", ConfigErrorCase.command(["id: [a]", "action: open_app", "app: x"]),
            .wrongType(path: "commands[0].id", expected: .text), 3, 9),
        .init(
            "aliases as text", ConfigErrorCase.command(["id: a", "aliases: b", "action: open_app", "app: x"]),
            .wrongType(path: "commands[0].aliases", expected: .list), 4, 14),
        .init(
            "alias as a mapping",
            ConfigErrorCase.command(["id: a", "aliases: [b, {c: d}]", "action: open_app", "app: x"]),
            .wrongType(path: "commands[0].aliases[1]", expected: .text), 4, 18),
        .init(
            "app as a mapping", ConfigErrorCase.command(["id: a", "action: open_app", "app: {path: x}"]),
            .wrongType(path: "commands[0].app", expected: .text), 5, 10),
        .init(
            "action as a list", ConfigErrorCase.command(["id: a", "action: [open_app]", "app: x"]),
            .wrongType(path: "commands[0].action", expected: .text), 4, 13),
    ]

    static let keys: [ConfigErrorCase] = [
        .init(
            "misspelt version", ["verison: 2"], .unknownKey("verison", path: "", suggestion: "version"), 1, 1),
        .init("unknown top key", ["version: 2", "zzz: 1"], .unknownKey("zzz", path: "", suggestion: nil), 2, 1),
        .init(
            "key in the wrong case", ["version: 2", "defaults:", "  Threshold: 0.5"],
            .unknownKey("Threshold", path: "defaults", suggestion: "threshold"), 3, 3),
        .init(
            "misspelt open_verbs", ["version: 2", "open_verb:", "  en: [open]"],
            .unknownKey("open_verb", path: "", suggestion: "open_verbs"), 2, 1),
        .init(
            "misspelt aliases", ConfigErrorCase.command(["id: a", "alises: [x]", "action: open_app", "app: x"]),
            .unknownKey("alises", path: "commands[0]", suggestion: "aliases"), 4, 5),
        .init(
            "a version 1 key in a command",
            ConfigErrorCase.command(["id: a", "action: open_app", "app: x", "target: y"]),
            .unknownKey("target", path: "commands[0]", suggestion: nil), 6, 5),
        .init(
            "misspelt insert", ["version: 2", "apps:", "  com.apple.mail:", "    insrt: paste"],
            .unknownKey("insrt", path: "apps.com.apple.mail", suggestion: "insert"), 4, 5),
        .init("list as a key", ["version: 2", "? [a]", ": b"], .unknownKey("[…]", path: "", suggestion: nil), 2, 3),
        .init("no version", ["commands: []"], .missingKey("version", path: ""), 1, 1),
        .init("null version", ["version:", "commands: []"], .missingKey("version", path: ""), 1, 1),
        .init(
            "command without an action", ConfigErrorCase.command(["id: a", "app: x"]),
            .missingKey("action", path: "commands[0]"), 3, 5),
        .init(
            "command without an app", ConfigErrorCase.command(["id: a", "action: open_app"]),
            .missingKey("app", path: "commands[0]"), 3, 5),
        .init(
            "command with a null id", ConfigErrorCase.command(["id: ~", "action: open_app", "app: x"]),
            .missingKey("id", path: "commands[0]"), 3, 5),
        .init(
            "app without insert", ["version: 2", "apps:", "  com.apple.mail: {}"],
            .missingKey("insert", path: "apps.com.apple.mail"), 3, 19),
        .init("version 1", ["version: 1"], .unsupportedVersion("1"), 1, 10),
        .init("version 2.0", ["version: 2.0"], .unsupportedVersion("2.0"), 1, 10),
        .init("quoted version", ["version: \"2\""], .unsupportedVersion("2"), 1, 10),
        .init("version as a word", ["version: two"], .unsupportedVersion("two"), 1, 10),
        .init(
            "version 1 wins over an earlier error", ["commands: [x]", "version: 1"], .unsupportedVersion("1"), 2, 10),
        .init(
            "bundle ID without a dot", ["version: 2", "apps:", "  mail:", "    insert: paste"],
            .invalidBundleID("mail"), 3, 3),
        .init(
            "bundle ID with an empty component", ["version: 2", "apps:", "  com..mail:", "    insert: paste"],
            .invalidBundleID("com..mail"), 3, 3),
        .init(
            "bundle ID ending in a dot", ["version: 2", "apps:", "  com.mail.:", "    insert: paste"],
            .invalidBundleID("com.mail."), 3, 3),
        .init(
            "bundle ID with a slash", ["version: 2", "apps:", "  com/apple.mail:", "    insert: paste"],
            .invalidBundleID("com/apple.mail"), 3, 3),
        .init(
            "bundle ID with an accent", ["version: 2", "apps:", "  cöm.apple.mail:", "    insert: paste"],
            .invalidBundleID("cöm.apple.mail"), 3, 3),
        .init(
            "bundle ID with a space", ["version: 2", "apps:", "  \"com.apple.mail \":", "    insert: paste"],
            .invalidBundleID("com.apple.mail "), 3, 3),
    ]

    static func threshold(_ value: String) -> [String] { ["version: 2", "defaults:", "  threshold: \(value)"] }

    static let values: [ConfigErrorCase] = [
        .init(
            "unknown action", ConfigErrorCase.command(["id: a", "action: open", "app: x"]),
            .invalidChoice(path: "commands[0].action", value: "open", allowed: actions), 4, 13),
        .init(
            "unknown insertion mode", ["version: 2", "apps:", "  com.apple.mail:", "    insert: type"],
            .invalidChoice(
                path: "apps.com.apple.mail.insert", value: "type", allowed: ["accessibility", "paste", "clipboard"]),
            4, 13),
        .init("threshold 0", threshold("0"), .outOfRange(path: "defaults.threshold", value: "0"), 3, 14),
        .init("threshold 0.0", threshold("0.0"), .outOfRange(path: "defaults.threshold", value: "0.0"), 3, 14),
        .init(
            "threshold just over 1", threshold("1.0000001"),
            .outOfRange(path: "defaults.threshold", value: "1.0000001"), 3, 14),
        .init("negative threshold", threshold("-0.5"), .outOfRange(path: "defaults.threshold", value: "-0.5"), 3, 14),
        .init("threshold as a word", threshold("high"), .outOfRange(path: "defaults.threshold", value: "high"), 3, 14),
        .init("quoted threshold", threshold("\"0.85\""), .outOfRange(path: "defaults.threshold", value: "0.85"), 3, 14),
        .init("hex threshold", threshold("0x1"), .outOfRange(path: "defaults.threshold", value: "0x1"), 3, 14),
        .init("NaN threshold", threshold(".nan"), .outOfRange(path: "defaults.threshold", value: ".nan"), 3, 14),
        .init("infinite threshold", threshold(".inf"), .outOfRange(path: "defaults.threshold", value: ".inf"), 3, 14),
        .init(
            "overflowing threshold", threshold("1e999"), .outOfRange(path: "defaults.threshold", value: "1e999"), 3, 14),
        .init(
            "threshold as a list", threshold("[0.5]"), .wrongType(path: "defaults.threshold", expected: .number), 3, 14),
        .init(
            "empty id", ConfigErrorCase.command(["id: \"\"", "action: open_app", "app: x"]),
            .emptyText(path: "commands[0].id"), 3, 9),
        .init(
            "blank id", ConfigErrorCase.command(["id: \"  \"", "action: open_app", "app: x"]),
            .emptyText(path: "commands[0].id"), 3, 9),
        .init(
            "app of punctuation", ConfigErrorCase.command(["id: a", "action: open_app", "app: \"?!\""]),
            .emptyText(path: "commands[0].app"), 5, 10),
        .init(
            "app that is a whisper annotation",
            ConfigErrorCase.command(["id: a", "action: open_app", "app: \"[BLANK_AUDIO]\""]),
            .emptyText(path: "commands[0].app"), 5, 10),
        .init(
            "blank app", ConfigErrorCase.command(["id: a", "action: open_app", "app: \" \\t\""]),
            .emptyText(path: "commands[0].app"), 5, 10),
        .init(
            "alias of an ellipsis",
            ConfigErrorCase.command(["id: a", "aliases: [b, \"…\"]", "action: open_app", "app: x"]),
            .emptyText(path: "commands[0].aliases[1]"), 4, 18),
        .init(
            "null alias", ConfigErrorCase.command(["id: a", "aliases: [b, ~]", "action: open_app", "app: x"]),
            .emptyText(path: "commands[0].aliases[1]"), 4, 18),
        .init(
            "verb of punctuation", ["version: 2", "open_verbs:", "  en: [open, \"!\"]"],
            .emptyText(path: "open_verbs.en[1]"), 3, 14),
        .init("blank filler", ["version: 2", "fillers:", "  fr: [\"\"]"], .emptyText(path: "fillers.fr[0]"), 3, 8),
        .init("null filler", ["version: 2", "fillers:", "  fr: [le, ~]"], .emptyText(path: "fillers.fr[1]"), 3, 12),
        .init(
            "an alias that is another command's app",
            ConfigErrorCase.command(["id: a", "action: open_app", "app: Finder"])
                + ["  - id: b", "    action: open_app", "    app: Safari", "    aliases: [\"Finder!\"]"],
            .collision(
                normalized: "finder", path: "commands[1].aliases[0]", otherPath: "commands[0].app",
                otherLocation: ConfigLocation(line: 5, column: 10)), 9, 15),
        .init(
            "one app by name and by path",
            ConfigErrorCase.command(["id: a", "action: open_app", "app: Finder"])
                + ["  - id: b", "    action: open_app", "    app: /System/Library/CoreServices/Finder.app"],
            .collision(
                normalized: "finder", path: "commands[1].app", otherPath: "commands[0].app",
                otherLocation: ConfigLocation(line: 5, column: 10)), 8, 10),
        .init(
            "an id used twice",
            ConfigErrorCase.command(["id: a", "action: open_app", "app: x"])
                + ["  - id: a", "    action: open_app", "    app: y"],
            .duplicateID("a", otherLocation: ConfigLocation(line: 3, column: 9)), 6, 9),
    ]
}

@Suite struct CommandConfigErrorTests {
    private func parseError(_ data: Data) -> ConfigError? {
        #expect(throws: ConfigError.self) { try CommandConfig.parse(data) }
    }

    @Test(
        arguments: ConfigErrorCases.syntax + ConfigErrorCases.structure + ConfigErrorCases.keys
            + ConfigErrorCases.values)
    func reportsTheProblemWhereItIs(_ testCase: ConfigErrorCase) {
        let error = parseError(Data(testCase.text.utf8))
        #expect(error?.problem == testCase.problem)
        #expect(error?.location == testCase.location)
    }

    /// libyaml counts CRLF as one line break, and `parse` turns it into LF anyway: the same error lands on the same
    /// line and column, with or without a BOM in front.
    @Test(
        arguments: ConfigErrorCases.syntax + ConfigErrorCases.structure + ConfigErrorCases.keys
            + ConfigErrorCases.values)
    func reportsTheSameLocationWithCRLFAndABOM(_ testCase: ConfigErrorCase) {
        let crlf = testCase.text.replacingOccurrences(of: "\n", with: "\r\n")
        let error = parseError(Data([0xEF, 0xBB, 0xBF]) + Data(crlf.utf8))
        #expect(error?.problem == testCase.problem)
        #expect(error?.location == testCase.location)
    }

    @Test func refusesAFileOverTheSizeCap() {
        let error = parseError(Data(repeating: 0x20, count: CommandConfig.maximumFileSize + 1))
        #expect(error == ConfigError(.tooLarge(bytes: CommandConfig.maximumFileSize + 1)))
    }

    @Test func acceptsAFileOfExactlyTheSizeCap() throws {
        let header = "version: 2\n# "
        let padding = String(repeating: "x", count: CommandConfig.maximumFileSize - header.utf8.count - 1)
        let data = Data((header + padding + "\n").utf8)
        #expect(data.count == CommandConfig.maximumFileSize)
        #expect(try CommandConfig.parse(data) == .empty)
    }

    @Test(
        arguments: [
            [0xFF], [0xE9], [0xC3], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80],
            [0xEF, 0xBB, 0xBF, 0xFE],
        ] as [[UInt8]])
    func refusesBytesThatAreNotUTF8(_ bytes: [UInt8]) {
        let error = parseError(Data("version: 2\ncommands: []\n# ".utf8) + Data(bytes))
        #expect(error == ConfigError(.notUTF8))
    }

    @Test func refusesALeadingInvalidByte() {
        #expect(parseError(Data([0xFE, 0xFF])) == ConfigError(.notUTF8))
    }

    @Test(arguments: [
        "", "\n\n", "   ", "# nothing here\n", "\u{FEFF}", "\u{FEFF}# comment\r\n", "---\n", "~\n", "null",
    ])
    func reportsAnEmptyFile(_ text: String) {
        #expect(parseError(Data(text.utf8)) == ConfigError(.empty))
    }

    /// Nine levels of nine: a billion "lol"s if the walker ever expanded the aliases.
    static func laughs(asCommands: Bool) -> String {
        let item = asCommands ? "  - " : ""
        var lines = ["version: 2"] + (asCommands ? ["commands:"] : [])
        lines.append(asCommands ? "\(item)&l0 \"lol\"" : "l0: &l0 \"lol\"")
        for level in 1...9 {
            let list = "[" + Array(repeating: "*l\(level - 1)", count: 9).joined(separator: ", ") + "]"
            lines.append(asCommands ? "\(item)&l\(level) \(list)" : "l\(level): &l\(level) \(list)")
        }
        return lines.map { $0 + "\n" }.joined()
    }

    @Test func refusesABillionLaughsQuickly() {
        var error: ConfigError?
        let elapsed = ContinuousClock().measure { error = parseError(Data(Self.laughs(asCommands: true).utf8)) }
        #expect(error == ConfigError(.anchorsNotSupported, at: ConfigLocation(line: 3, column: 5)))
        #expect(elapsed < .seconds(1))

        let classic = ContinuousClock().measure { error = parseError(Data(Self.laughs(asCommands: false).utf8)) }
        #expect(error?.location == ConfigLocation(line: 2, column: 1))
        #expect(classic < .seconds(1))
    }
}
