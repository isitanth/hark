import Foundation

/// What would make a command typed in the Commands tab unusable, said in terms of the command rather than of the YAML
/// Hark would write for it: the parser's errors name paths in a file the user never saw.
public enum CommandDraftProblem: Sendable, Equatable {
    /// The app's name has no letter or digit to say.
    case appUnsayable
    /// An alias with no letter or digit to say.
    case aliasUnsayable(String)
    /// The app's name or an alias is exactly one filler, which the matcher skips before it looks for an app.
    case onlyFillers(String)
    /// The app's name or an alias, as typed, already says another command, named by that command's spoken app name.
    case collision(String, otherApp: String)
}

extension CommandEntry {
    /// The problems of a draft against the config it will join, in the order the editor shows them. `id` is the command
    /// the draft edits, whose own names are not collisions.
    public static func problems(
        app: String, aliases: [String], in config: CommandConfig, editing id: String? = nil
    ) -> [CommandDraftProblem] {
        var others: [String: String] = [:]
        for command in config.commands where command.id != id {
            for form in command.forms { others[Normalizer.normalize(form)] = command.spokenName }
        }
        var problems: [CommandDraftProblem] = []
        let spoken = spokenName(of: app)
        if Normalizer.normalize(spoken).isEmpty {
            problems.append(.appUnsayable)
        } else if CommandMatcher.isOnlyFillers(spoken, in: config) {
            problems.append(.onlyFillers(spoken))
        } else if let other = others[Normalizer.normalize(spoken)] {
            problems.append(.collision(spoken, otherApp: other))
        }
        for alias in aliases {
            if Normalizer.normalize(alias).isEmpty {
                problems.append(.aliasUnsayable(alias))
            } else if CommandMatcher.isOnlyFillers(alias, in: config) {
                problems.append(.onlyFillers(alias))
            } else if let other = others[Normalizer.normalize(alias)] {
                problems.append(.collision(alias, otherApp: other))
            }
        }
        return problems
    }
}
