import Foundation

/// commands.yaml, schema version 3. A plain value: where each item sat in the file is only kept for error messages.
/// A version 2 file still reads, as version 3 without `llm:`.
///
/// ```yaml
/// version: 3                  # required, 3 (or 2, which cannot have llm:)
/// defaults:                   # optional
///   threshold: 0.85           # how close a spoken app name must be, 0 < threshold <= 1
/// apps:                       # optional, bundle ID -> override
///   com.tinyspeck.slackmacgap:
///     insert: paste           # accessibility | paste | clipboard
/// open_verbs:                 # optional, language -> words; a command starts with one of them
///   en: [open, launch]
///   fr: [ouvre, lance]
/// fillers:                    # optional, language -> words skipped between the verb and the app
///   en: [the, my]
///   fr: [le, la]
/// endings:                    # optional, version 3 only, language -> what may follow the app; absent, the default
///   en: [please]
///   fr: ["s'il te plaît"]
/// commands:                   # optional; empty or null is an empty table
///   - id: open_finder         # required, unique
///     action: open_app        # open_app
///     app: "Finder"           # required: an application's name, or a path to it; its name is also an alias
///     aliases: ["fichiers"]   # optional
/// llm:                        # optional, version 3 only; see LLMConfig
///   provider: local           # a key of profiles
///   profiles:
///     local:                  # ^[a-z0-9][a-z0-9_-]{0,31}$, also the Keychain account
///       base_url: "http://127.0.0.1:8000/v1"   # https, or http to this Mac only
///       key: keychain         # keychain | none; the key itself never goes in this file
///       model: auto           # auto, or a model id
///       temperature: 0.3      # 0...2
///       max_tokens: 1024      # 1...131072
///       extra: { enable_thinking: false }      # scalars only, sent as top-level request fields
///   max_selection_chars: 12000                 # 1...100000
/// assistant:                  # optional, version 3 only; see AssistantConfig
///   prefix: [hark, arc, ark, arke]   # a dictation starting with one of these goes to the assistant
///   greetings: [hey, hello, salut]   # may come before the prefix, never alone
/// ```
///
/// Any other key is an error, and so is an alias that normalizes to the same text as another command's.
public struct CommandConfig: Sendable, Equatable {
    public static let supportedVersion = 3
    /// Older versions that still read: 2 is 3 without `llm:`.
    public static let readableVersions: Set<Int> = [2, 3]
    /// A command table this size is already absurd. The cap keeps a stray binary file from reaching the parser.
    public static let maximumFileSize = 256 * 1024

    public var defaults: CommandDefaults
    /// Keyed by bundle ID, as written in the file.
    public var apps: [String: AppOverride]
    /// Language -> words, as written. Every language is tried on every utterance; the grouping is for whoever edits
    /// the file.
    public var openVerbs: [String: [String]]
    public var fillers: [String: [String]]
    /// Nil when the file has no `endings:`, as for `assistant`; what the matcher uses is `effectiveEndings`.
    public var endings: [String: [String]]?
    public var commands: [CommandEntry]
    /// Nil when the file has no `llm:`. Kept as read, so writing the file back never adds a block the user did not
    /// write; what an ask uses is `effectiveLLM`.
    public var llm: LLMConfig?
    /// Nil when the file has no `assistant:`, for the same reason; what the resolver uses is `effectiveAssistant`.
    public var assistant: AssistantConfig?

    public init(
        defaults: CommandDefaults = CommandDefaults(), apps: [String: AppOverride] = [:],
        openVerbs: [String: [String]] = [:], fillers: [String: [String]] = [:], endings: [String: [String]]? = nil,
        commands: [CommandEntry] = [], llm: LLMConfig? = nil, assistant: AssistantConfig? = nil
    ) {
        self.defaults = defaults
        self.apps = apps
        self.openVerbs = openVerbs
        self.fillers = fillers
        self.endings = endings
        self.commands = commands
        self.llm = llm
        self.assistant = assistant
    }

    /// What an ask uses: the file's `llm:`, or the local profile alone.
    public var effectiveLLM: LLMConfig {
        llm ?? .standard
    }

    /// What the resolver uses: the file's `assistant:`, or `AssistantConfig.standard`.
    public var effectiveAssistant: AssistantConfig {
        assistant ?? .standard
    }

    /// What the matcher allows after the app: the file's `endings:`, or `defaultEndings`.
    public var effectiveEndings: [String: [String]] {
        endings ?? Self.defaultEndings
    }

    /// The polite endings the user allowed after the app on 2026-09-29: "ouvre Safari, s'il te plaît".
    public static let defaultEndings = ["en": ["please"], "fr": ["s'il te plaît", "s'il vous plaît"]]

    public static let empty = CommandConfig()
}

public struct CommandDefaults: Sendable, Equatable {
    /// How close a spoken app name has to be to an alias, as a Jaro-Winkler score.
    public var threshold: Double

    public init(threshold: Double = 0.85) {
        self.threshold = threshold
    }
}

/// How text reaches the focused app. `clipboard` never types into the app at all.
public enum InsertionMode: String, Sendable, CaseIterable {
    case accessibility
    case paste
    case clipboard
}

/// One entry of the `apps:` table: what to do differently when this app is frontmost.
public struct AppOverride: Sendable, Equatable {
    public var insert: InsertionMode

    public init(insert: InsertionMode) {
        self.insert = insert
    }
}

public struct CommandEntry: Sendable, Equatable {
    public var id: String
    public var action: ActionType
    /// As written: an application's name ("Finder", "System Settings") or a path to one.
    public var app: String
    /// As written. The app's own name is an alias without being listed.
    public var aliases: [String]

    public init(id: String, action: ActionType = .openApp, app: String, aliases: [String] = []) {
        self.id = id
        self.action = action
        self.app = app
        self.aliases = aliases
    }

    /// What the app is called out loud: its name, or for a path the bundle's file name, without `.app` either way.
    public var spokenName: String {
        Self.spokenName(of: app)
    }

    /// Every form the command answers to, as written: the app's name first, then the aliases.
    public var forms: [String] {
        [spokenName] + aliases
    }

    public var resolved: ResolvedCommand {
        ResolvedCommand(id: id, action: action, target: app)
    }

    static func spokenName(of app: String) -> String {
        let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = trimmed.contains("/") ? URL(filePath: trimmed).lastPathComponent : trimmed
        return file.lowercased().hasSuffix(".app") ? String(file.dropLast(4)) : file
    }
}

extension CommandConfig {
    /// Parses and validates commands.yaml. Accepts a UTF-8 BOM and CRLF line endings.
    public static func parse(_ data: Data) throws(ConfigError) -> CommandConfig {
        try CommandConfigParser.parse(data)
    }

    /// Canonical YAML for this config: `version`, `defaults`, `apps`, `open_verbs`, `fillers`, `endings`, `commands`,
    /// `llm`, `assistant`, in that order, every string double-quoted so that YAML can never read it as something else. For every config the
    /// parser can produce, `parse(yaml())` gives back an equal value; one built in code with a number that is not
    /// finite, or a model named "auto", does not. Comments are not preserved, because the value never had them.
    public func yaml() -> String {
        CommandConfigEmitter.yaml(for: self)
    }
}

extension CommandEntry {
    /// An id for a command added in Settings: `open_` and the app's spoken name as lowercase words joined by `_`,
    /// numbered when `taken` already has it.
    public static func newID(for app: String, taken: Set<String>) -> String {
        let words = Normalizer.normalize(spokenName(of: app)).split(separator: " ").joined(separator: "_")
        let base = "open_" + (words.isEmpty ? "app" : words)
        var id = base
        var number = 2
        while taken.contains(id) {
            id = "\(base)_\(number)"
            number += 1
        }
        return id
    }

    /// The editor's aliases field: separated by commas, trimmed, empty ones dropped.
    public static func aliases(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
