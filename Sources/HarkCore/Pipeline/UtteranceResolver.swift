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
    private let spokenPrefix = OSAllocatedUnfairLock(initialState: SpokenPrefix.standard)

    public init(_ values: Values = Values()) {
        lock = OSAllocatedUnfairLock(initialState: values)
    }

    public var current: Values {
        lock.withLock { $0 }
    }

    public var commands: CommandMatcher {
        matcher.withLock { $0 }
    }

    public var prefix: SpokenPrefix {
        spokenPrefix.withLock { $0 }
    }

    public func update(commands config: CommandConfig) {
        let built = CommandMatcher(config: config)
        matcher.withLock { $0 = built }
        let prefix = SpokenPrefix(config.effectiveAssistant)
        spokenPrefix.withLock { $0 = prefix }
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

/// The assistant's spoken prefix first ("Hark, …", M9.2), then a command, by your template: an opening verb, then an
/// app (`CommandMatcher`). Anything else is text, delivered as `FocusResolver` decides. A command runs whatever has
/// focus, a password field included; the log line still hides what was said there. A password field is never sent to
/// the assistant: what is said there stays dictation.
public struct UtteranceResolver: UtteranceResolving {
    private let settings: ResolutionSettings
    private let selection: (any SelectionReading)?

    /// `selection` reads what the app had selected when a spoken prefix is found; nil reads nothing.
    public init(settings: ResolutionSettings, selection: (any SelectionReading)? = nil) {
        self.settings = settings
        self.selection = selection
    }

    public func resolve(_ transcript: Transcript, focus: FocusSnapshot?) async -> (
        normalized: String?, decision: Decision
    ) {
        let normalized = Normalizer.normalize(transcript.raw)
        if focus?.isSecureInput != true, let request = settings.prefix.request(in: transcript.raw) {
            guard !request.isEmpty else { return (normalized, .discard(.emptyRequest)) }
            // "Arc, ouvre TextEdit" is a command said to Hark: it runs, as it would without the prefix.
            if let found = settings.commands.match(Normalizer.normalize(request)) {
                return (normalized, .command(found.command))
            }
            // Read now, not at the press: only a prefix earns the read, and the ⌘C it may take (M9.0).
            let selected = await selection?.read(from: focus?.app)
            return (normalized, .ask(request: request, selection: selected))
        }
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
