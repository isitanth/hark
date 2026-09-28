import Foundation
import HarkCore
import Testing

enum ConfigFixtures {
    static func data(_ name: String) throws -> Data {
        let directory = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func parse(_ text: String) throws -> CommandConfig {
        try CommandConfig.parse(Data(text.utf8))
    }

    /// Fixtures/commands.yaml, the bundled default, spelled out.
    static let commands = CommandConfig(
        defaults: CommandDefaults(threshold: 0.85),
        openVerbs: [
            "en": ["open", "launch", "show", "start"],
            "fr": ["ouvre", "ouvrir", "lance", "lancer", "affiche", "afficher", "démarre", "démarrer"],
        ],
        fillers: [
            "en": ["the", "a", "an", "my", "your", "our", "this", "that"],
            "fr": [
                "le", "la", "les", "l", "un", "une", "du", "de", "d", "des", "mon", "ma", "mes", "ton", "ta", "tes",
                "son", "sa", "ses", "notre", "votre", "nos", "vos", "ce", "cet", "cette", "ces", "moi",
            ],
        ],
        commands: [
            CommandEntry(id: "open_finder", app: "Finder"),
            CommandEntry(id: "open_safari", app: "Safari"),
            CommandEntry(id: "open_notes", app: "Notes", aliases: ["note"]),
            CommandEntry(id: "open_mail", app: "Mail"),
            CommandEntry(id: "open_messages", app: "Messages"),
            CommandEntry(id: "open_calendar", app: "Calendar", aliases: ["calendrier"]),
            CommandEntry(id: "open_music", app: "Music", aliases: ["musique"]),
            CommandEntry(
                id: "open_system_settings", app: "System Settings",
                aliases: ["settings", "réglages", "réglages système"]),
            CommandEntry(id: "open_terminal", app: "Terminal"),
        ],
        llm: .standard)

    /// Every optional field set, and strings that would each break a naive emitter: quotes, backslashes, `#`, `: `,
    /// leading spaces, YAML keywords, emoji, line breaks, control characters and scripts other than Latin.
    static let awkward = CommandConfig(
        defaults: CommandDefaults(threshold: 0.123456789),
        apps: [
            "com.tinyspeck.slackmacgap": AppOverride(insert: .paste),
            "com.apple.mail": AppOverride(insert: .clipboard),
            "org.example.Some_App-2": AppOverride(insert: .accessibility),
        ],
        openVerbs: [
            "en": ["open", "  leading", "say \"hi\""], "fr-CA": ["ouvre", "démarre"], "yes": ["true", "null"],
        ],
        fillers: ["#": ["# not a comment"], "x": [], "ja": ["東京 タワー", "🎉 party"]],
        commands: [
            CommandEntry(
                id: "say \"hi\"", app: "/Applications/Some App.app",
                aliases: ["back\\slash", "# not a comment", "key: value", "- [x] {y}"]),
            CommandEntry(id: "  leading spaces", app: "  Москва", aliases: ["🎉 party", "ouvre l’app"]),
            CommandEntry(id: "true", app: "null", aliases: ["42", "yes", "0x1F", "&anchor", "*alias", "!tag"]),
            CommandEntry(
                id: "control\r\n\t\u{0}\u{1B}", app: "tab\there",
                aliases: ["del\u{7F}x", "nel\u{85}ls\u{2028}ps\u{2029}end", "bom\u{FEFF}z"]),
        ])
}

@Suite struct CommandConfigTests {
    @Test func fixtureParsesToTheExpectedValue() throws {
        let config = try CommandConfig.parse(try ConfigFixtures.data("commands.yaml"))
        #expect(config == ConfigFixtures.commands)
        #expect(config.commands.map(\.id) == ConfigFixtures.commands.commands.map(\.id))
    }

    @Test func bundledDefaultIsTheFixture() throws {
        let url = try #require(BundledResources.defaultCommands)
        let bundled = try Data(contentsOf: url)
        #expect(bundled == (try ConfigFixtures.data("commands.yaml")))
        #expect(try CommandConfig.parse(bundled) == ConfigFixtures.commands)
    }

    @Test(arguments: [ConfigFixtures.commands, ConfigFixtures.awkward, .empty])
    func parsingTheEmittedTextGivesTheValueBack(_ config: CommandConfig) throws {
        let text = config.yaml()
        #expect(try ConfigFixtures.parse(text) == config, "\(text)")
        #expect(try ConfigFixtures.parse(text).yaml() == text)
    }

    @Test func emitsTheCanonicalText() {
        let config = CommandConfig(
            openVerbs: ["fr": ["ouvre"], "en": ["open", "launch"]], fillers: ["en": ["the"]],
            commands: [
                CommandEntry(id: "open_finder", app: "Finder"),
                CommandEntry(id: "open_notes", app: "Notes", aliases: ["note", "mes notes"]),
            ])
        let expected = """
            version: 3

            defaults:
              threshold: 0.85

            open_verbs:
              "en": ["open", "launch"]
              "fr": ["ouvre"]

            fillers:
              "en": ["the"]

            commands:
              - id: "open_finder"
                action: open_app
                app: "Finder"

              - id: "open_notes"
                action: open_app
                app: "Notes"
                aliases: ["note", "mes notes"]

            """
        #expect(config.yaml() == expected)
    }

    @Test func emitsAppsSortedAndAnEmptyTableAsAnEmptyList() {
        let config = CommandConfig(
            defaults: CommandDefaults(threshold: 1),
            apps: ["com.b.app": AppOverride(insert: .paste), "com.a.app": AppOverride(insert: .clipboard)])
        let expected = """
            version: 3

            defaults:
              threshold: 1

            apps:
              "com.a.app":
                insert: clipboard
              "com.b.app":
                insert: paste

            commands: []

            """
        #expect(config.yaml() == expected)
    }

    @Test func escapesLikeJSON() {
        let config = CommandConfig(commands: [
            CommandEntry(id: "a\"b\\c", app: "\n\r\t\u{8}\u{C}\u{0}\u{7F}\u{85}\u{2028}\u{FEFF}é🎉")
        ])
        let text = config.yaml()
        #expect(text.contains(#"  - id: "a\"b\\c""#))
        let escapes = ["n", "r", "t", "b", "f", "u0000", "u007F", "u0085", "u2028", "uFEFF"].map { #"\"# + $0 }
        #expect(text.contains("    app: \"" + escapes.joined() + "é🎉\""))
    }

    /// The name a command answers to without an alias: the app's name, or the bundle's file name for a path.
    @Test(arguments: [
        ("Finder", "Finder"), ("  System Settings ", "System Settings"),
        ("/System/Library/CoreServices/Finder.app", "Finder"), ("~/Applications/My Tool.app", "My Tool"),
        ("/Applications/Utilities/Terminal.APP", "Terminal"), ("/opt/tools/runner", "runner"), ("Safari.app", "Safari"),
    ])
    func theAppsSpokenName(_ app: String, _ spoken: String) {
        #expect(CommandEntry(id: "x", app: app).spokenName == spoken)
    }

    /// Your example listed the app's own name as an alias; that repeat is dropped, keeping the first spelling.
    @Test func anAliasThatRepeatsTheAppsNameIsDropped() throws {
        let config = try ConfigFixtures.parse(
            """
            version: 2
            commands:
              - id: open_finder
                action: open_app
                app: "Finder"
                aliases: [Finder, finder, "Finder !", "le finder"]
            """)
        #expect(config.commands.first?.aliases == ["le finder"])
    }
}
