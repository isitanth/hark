import HarkCore
import SwiftUI

/// How one log entry reads, wherever it is shown: the panel's LAST and RECENT and the Log tab.
extension LogEntry {
    var outcome: EntryOutcome {
        EntryOutcome(self)
    }

    var kindText: LocalizedStringResource {
        switch resolution {
        case .command: L("entry.kind.command")
        case .textInserted, .textClipboard: L("entry.kind.text")
        case .discarded: L("entry.kind.discarded")
        case .failed: L("entry.kind.failed")
        }
    }

    /// The app the text was meant for, by name, or nil when the log did not know it.
    var appName: String? {
        guard let targetApp, targetApp != "unknown" else { return nil }
        return AppNames.name(for: targetApp)
    }

    /// What the log itself says, for a tooltip: the bundle ID and the error code behind the words.
    var logDetail: String {
        [targetApp, error].compactMap(\.self).joined(separator: " · ")
    }

    /// Interpolations stay plain identifiers, so the strings gate can read every key straight from the source.
    var outcomeText: LocalizedStringResource {
        guard outcome.isCut else { return wholeOutcomeText }
        let outcome = String(localized: wholeOutcomeText)
        let minutes = Int(SampleBuffer.defaultMaxDuration.components.seconds / 60)
        return L("entry.outcome.cut \(outcome) \(minutes)")
    }

    private var wholeOutcomeText: LocalizedStringResource {
        let unknown = "?"
        switch outcome {
        case .command(ActionType.openApp.rawValue, _):
            return L("entry.outcome.openedApp")
        case .command(let action, _):
            let action = action ?? unknown
            return L("entry.outcome.command \(action)")
        case .inserted:
            let app = appName ?? unknown
            return L("entry.outcome.inserted \(app)")
        case .copied(let reason):
            return Self.copyText(reason)
        case .discarded(let reason, let code):
            let reason = String(localized: Self.reason(reason, code))
            return L("entry.outcome.discarded \(reason)")
        case .failed(let reason):
            return Self.failureText(reason, code: error ?? unknown)
        }
    }

    /// The design brief's dots: green for a command, blue for text, and orange for text that was meant for a field
    /// and only reached the clipboard, or for a capture that stopped at the length limit.
    var dotColor: Color {
        switch resolution {
        case .command: outcome.isCut ? .orange : .green
        case .textInserted: outcome.isCut ? .orange : .blue
        case .textClipboard: outcome.isFallback ? .orange : .blue
        case .discarded: .secondary
        case .failed: .red
        }
    }

    private static func copyText(_ reason: EntryOutcome.CopyReason) -> LocalizedStringResource {
        switch reason {
        case .chosen: L("entry.outcome.clipboard")
        case .noTextField: L("entry.outcome.copied.noTextField")
        case .secureField: L("entry.outcome.copied.secureField")
        case .focusChanged: L("entry.outcome.copied.focusChanged")
        case .insertionFailed: L("entry.outcome.copied.insertionFailed")
        case .insertionTimedOut: L("entry.outcome.copied.insertionTimedOut")
        case .pasteNotConsumed: L("entry.outcome.copied.pasteNotConsumed")
        case .selectionChanged: L("entry.outcome.copied.selectionChanged")
        case .other(let code): L("entry.outcome.clipboardFallback \(code)")
        }
    }

    /// Words for what can fail today. The command failures no action raises yet keep their code. A failed command's
    /// notification says it in the same words.
    nonisolated static func failureText(_ reason: EntryOutcome.FailureReason, code: String) -> LocalizedStringResource {
        switch reason {
        case .microphoneDenied: return L("entry.failure.microphoneDenied")
        case .noInputDevice: return L("entry.failure.noInputDevice")
        case .deviceChanged: return L("entry.failure.deviceChanged")
        case .audioEngine(let number?): return L("entry.failure.audioEngine \(number)")
        case .modelMissing: return L("entry.failure.modelMissing")
        case .modelLoad: return L("entry.failure.modelLoad")
        case .transcription(let number?): return L("entry.failure.transcription \(number)")
        case .pasteboardWrite: return L("entry.failure.pasteboardWrite")
        case .appNotFound(let name?): return L("entry.failure.appNotFound \(name)")
        case .appNotActivated(let name?): return L("entry.failure.appNotActivated \(name)")
        case .appExited(let name?): return L("entry.failure.appExited \(name)")
        case .quitting: return L("entry.failure.quitting")
        case .actionLaunch: return L("entry.failure.actionLaunch")
        case .actionTimeout: return L("entry.failure.actionTimeout")
        case .llmUnreachable: return L("entry.failure.llmUnreachable")
        case .llmUnauthorized: return L("entry.failure.llmUnauthorized")
        case .llmTimeout: return L("entry.failure.llmTimeout")
        case .llmError(let status?): return L("entry.failure.llmError \(status)")
        case .llmError(nil): return L("entry.failure.llmErrorInStream")
        case .llmEmpty: return L("entry.failure.llmEmpty")
        case .audioEngine(nil), .transcription(nil), .appNotFound(nil), .appNotActivated(nil), .appExited(nil),
            .actionExit, .automationDenied, .focusNotRestored, .other:
            return L("entry.outcome.failed \(code)")
        }
    }

    /// The discard reasons are a closed set (`DiscardReason`), so each gets words; anything else shows its code.
    private static func reason(_ reason: DiscardReason?, _ code: String?) -> LocalizedStringResource {
        switch reason {
        case .cancelled: return L("entry.reason.cancelled")
        case .tooShort: return L("entry.reason.tooShort")
        case .noSpeech: return L("entry.reason.noSpeech")
        case .emptyTranscript: return L("entry.reason.emptyTranscript")
        case .declined: return L("entry.reason.declined")
        case .busy: return L("entry.reason.busy")
        case .maxDuration: return L("entry.reason.maxDuration")
        case .clipboardFallbackDisabled: return L("entry.reason.clipboardFallbackDisabled")
        case .emptySelection: return L("entry.reason.emptySelection")
        case nil:
            let raw = code ?? "?"
            return L("entry.reason.other \(raw)")
        }
    }
}

/// A commands.yaml error in the user's language. The paths and values stay as written in the file.
extension ConfigError {
    var locationText: LocalizedStringResource? {
        guard let location else { return nil }
        let line = location.line
        let column = location.column
        return L("config.location \(line) \(column)")
    }

    var problemText: LocalizedStringResource {
        switch problem {
        case .unreadable(let errno):
            let code = Int(errno)
            return L("config.problem.unreadable \(code)")
        case .tooLarge(let bytes): return L("config.problem.tooLarge \(bytes)")
        case .notUTF8: return L("config.problem.notUTF8")
        case .syntax(let message): return L("config.problem.syntax \(message)")
        case .empty: return L("config.problem.empty")
        case .anchorsNotSupported: return L("config.problem.anchors")
        case .duplicateKey(let key, _): return L("config.problem.duplicateKey \(key)")
        case .wrongType(let path, let expected): return Self.wrongType(Self.subject(path), expected)
        case .unknownKey(let key, _, let suggestion?):
            return L("config.problem.unknownKeySuggestion \(key) \(suggestion)")
        case .unknownKey(let key, _, nil): return L("config.problem.unknownKey \(key)")
        case .missingKey(let key, _): return L("config.problem.missingKey \(key)")
        case .unsupportedVersion(let version): return L("config.problem.unsupportedVersion \(version)")
        case .invalidChoice(let path, let value, let allowed):
            let choices = allowed.joined(separator: ", ")
            return L("config.problem.invalidChoice \(path) \(value) \(choices)")
        case .outOfRange(let path, let value): return L("config.problem.outOfRange \(path) \(value)")
        case .emptyText(let path): return L("config.problem.emptyText \(path)")
        case .invalidBundleID(let id): return L("config.problem.invalidBundleID \(id)")
        case .collision(let normalized, let path, let otherPath, let other):
            let line = other.line
            return L("config.problem.collision \(normalized) \(path) \(otherPath) \(line)")
        case .duplicateID(let id, let other):
            let line = other.line
            return L("config.problem.duplicateID \(id) \(line)")
        }
    }

    /// The top level has no path; it is the file itself.
    private static func subject(_ path: String) -> String {
        path.isEmpty ? String(localized: L("config.path.document")) : path
    }

    private static func wrongType(_ subject: String, _ kind: ConfigValueKind) -> LocalizedStringResource {
        switch kind {
        case .mapping: L("config.problem.expectedMapping \(subject)")
        case .list: L("config.problem.expectedList \(subject)")
        case .text: L("config.problem.expectedText \(subject)")
        case .number: L("config.problem.expectedNumber \(subject)")
        case .boolean: L("config.problem.expectedBoolean \(subject)")
        }
    }
}
