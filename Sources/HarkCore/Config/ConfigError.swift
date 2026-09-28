import Foundation

/// A position in commands.yaml, both 1-based. Columns count Unicode scalars, as libyaml does.
public struct ConfigLocation: Sendable, Hashable, CustomStringConvertible {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String { "line \(line), column \(column)" }
}

/// The YAML kind a key expected, for `ConfigProblem.wrongType`.
public enum ConfigValueKind: String, Sendable, CaseIterable {
    case mapping
    case list
    case text
    case number
    case boolean
}

/// Everything that can make commands.yaml unusable. Each case maps to one localized message in HarkApp, so adding a
/// case means adding a string.
///
/// `path` names the node in the document: `defaults.threshold`, `commands[3].aliases[1]`, `apps.com.apple.mail`.
/// Indexes are 0-based; the line and column in `ConfigError.location` are what a person should look at.
public enum ConfigProblem: Sendable, Equatable {
    /// The file exists but could not be read.
    case unreadable(errno: Int32)
    /// Larger than `CommandConfig.maximumFileSize`.
    case tooLarge(bytes: Int)
    case notUTF8
    /// libyaml rejected the text. The string is its own description, in English.
    case syntax(String)
    /// Nothing but whitespace and comments.
    case empty
    /// `&anchor` or `*alias`. A command table never needs them, and they are the one YAML feature that lets a small
    /// file expand without bound.
    case anchorsNotSupported
    /// The same key twice in one mapping. For `apps`, bundle IDs are compared case-insensitively.
    case duplicateKey(String, path: String)
    case wrongType(path: String, expected: ConfigValueKind)
    /// `path` is the mapping that holds the key; empty for the top level. `suggestion` is the closest valid key.
    case unknownKey(String, path: String, suggestion: String?)
    case missingKey(String, path: String)
    case unsupportedVersion(String)
    case invalidChoice(path: String, value: String, allowed: [String])
    /// Not a number, or a number outside the range the key allows.
    case outOfRange(path: String, value: String)
    /// An id that is blank, or an app, alias, verb or filler that normalizes to nothing.
    case emptyText(path: String)
    case invalidBundleID(String)
    /// Two aliases, or an alias and an app's name, that normalize to the same text. `location` in the error points
    /// at the second.
    case collision(normalized: String, path: String, otherPath: String, otherLocation: ConfigLocation)
    /// A command `id` already used by an earlier command, which `otherLocation` points at.
    case duplicateID(String, otherLocation: ConfigLocation)
}

public struct ConfigError: Error, Sendable, Equatable, CustomStringConvertible {
    public let problem: ConfigProblem
    /// Where to look. Nil for problems that belong to the whole file (unreadable, too large, not UTF-8, empty).
    public let location: ConfigLocation?

    public init(_ problem: ConfigProblem, at location: ConfigLocation? = nil) {
        self.problem = problem
        self.location = location
    }

    /// English, for `os.Logger` and tests. The UI localizes `problem` instead.
    public var description: String {
        let detail: String =
            switch problem {
            case .unreadable(let errno): "cannot read the file (errno \(errno))"
            case .tooLarge(let bytes): "the file is \(bytes) bytes, over the \(CommandConfig.maximumFileSize) limit"
            case .notUTF8: "the file is not UTF-8"
            case .syntax(let message): "YAML syntax: \(message)"
            case .empty: "the file is empty"
            case .anchorsNotSupported: "YAML anchors and aliases are not supported"
            case .duplicateKey(let key, let path): "duplicate key '\(key)'\(Self.in(path))"
            case .wrongType(let path, let expected): "\(path) must be \(expected.rawValue)"
            case .unknownKey(let key, let path, let suggestion):
                "unknown key '\(key)'\(Self.in(path))" + (suggestion.map { ", did you mean '\($0)'?" } ?? "")
            case .missingKey(let key, let path): "missing key '\(key)'\(Self.in(path))"
            case .unsupportedVersion(let version):
                "unsupported version \(version), expected \(CommandConfig.supportedVersion)"
            case .invalidChoice(let path, let value, let allowed):
                "\(path): '\(value)' is not one of \(allowed.joined(separator: ", "))"
            case .outOfRange(let path, let value): "\(path): '\(value)' is out of range"
            case .emptyText(let path): "\(path) is empty"
            case .invalidBundleID(let id): "'\(id)' is not a bundle identifier"
            case .collision(let normalized, let path, let otherPath, let otherLocation):
                "\(path) and \(otherPath) (\(otherLocation)) both normalize to '\(normalized)'"
            case .duplicateID(let id, let otherLocation): "id '\(id)' is already used at \(otherLocation)"
            }
        return location.map { "\($0): \(detail)" } ?? detail
    }

    private static func `in`(_ path: String) -> String {
        path.isEmpty ? "" : " in \(path)"
    }
}
