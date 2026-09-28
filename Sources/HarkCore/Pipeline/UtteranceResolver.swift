import Foundation
import os

/// What the resolver reads on every utterance. HarkApp updates it when commands.yaml reloads or a preference changes.
public final class ResolutionSettings: Sendable {
    public struct Values: Sendable, Equatable {
        public var insertionMode: InsertionMode
        /// Off means text that cannot be inserted is discarded instead of copied. A copy the user chose —
        /// clipboard-only mode, or an `apps:` entry that says clipboard — is not a fallback and still happens.
        public var clipboardFallback: Bool
        public var apps: [String: AppOverride]

        public init(
            insertionMode: InsertionMode = .accessibility, clipboardFallback: Bool = true,
            apps: [String: AppOverride] = [:]
        ) {
            self.insertionMode = insertionMode
            self.clipboardFallback = clipboardFallback
            self.apps = apps
        }
    }

    private let lock: OSAllocatedUnfairLock<Values>
    /// Built once per commands.yaml, not once per utterance.
    private let matcher = OSAllocatedUnfairLock(initialState: CommandMatcher.empty)

    public init(_ values: Values = Values()) {
        lock = OSAllocatedUnfairLock(initialState: values)
    }

    public var current: Values {
        lock.withLock { $0 }
    }

    public var commands: CommandMatcher {
        matcher.withLock { $0 }
    }

    public func update(commands config: CommandConfig) {
        let built = CommandMatcher(config: config)
        matcher.withLock { $0 = built }
    }

    public func update(insertionMode: InsertionMode) {
        lock.withLock { $0.insertionMode = insertionMode }
    }

    public func update(clipboardFallback: Bool) {
        lock.withLock { $0.clipboardFallback = clipboardFallback }
    }

    public func update(apps: [String: AppOverride]) {
        lock.withLock { $0.apps = apps }
    }
}

/// A command first, by your template: an opening verb, then an app (`CommandMatcher`). Anything else is text,
/// delivered as `FocusResolver` decides. A command runs whatever has focus, a password field included; the log line
/// still hides what was said there.
public struct UtteranceResolver: UtteranceResolving {
    private let settings: ResolutionSettings

    public init(settings: ResolutionSettings) {
        self.settings = settings
    }

    public func resolve(_ transcript: Transcript, focus: FocusSnapshot?) async -> (
        normalized: String?, decision: Decision
    ) {
        let normalized = Normalizer.normalize(transcript.raw)
        if let found = settings.commands.match(normalized) {
            return (normalized, .command(found.command))
        }
        let values = settings.current
        return (
            normalized,
            FocusResolver.decide(
                focus: focus, global: values.insertionMode, apps: values.apps,
                clipboardFallback: values.clipboardFallback)
        )
    }
}
