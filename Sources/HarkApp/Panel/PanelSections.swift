import AppKit
import HarkCore
import SwiftUI

/// One row per standing problem, most severe first, each with the one thing that fixes it.
struct HealthRows: View {
    let model: AppModel
    let openModelSettings: () -> Void
    let openAskSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.health.issues, id: \.self) { issue in
                switch issue {
                case .configInvalid:
                    if let error = model.config.error {
                        ConfigErrorRow(error: error, source: model.config.source, reveal: model.revealCommandsFile)
                    }
                case .modelNotLoaded:
                    IssueRow(symbol: "cpu", severity: issue.severity, text: modelText, action: L("panel.model.choose"))
                    {
                        openModelSettings()
                    }
                case .microphoneDenied:
                    IssueRow(
                        symbol: "mic.slash", severity: issue.severity, text: L("permission.microphone.missing"),
                        action: L("permission.openSystemSettings")
                    ) {
                        model.openPrivacySettings(.microphone)
                    }
                case .accessibilityNotTrusted:
                    IssueRow(
                        symbol: "accessibility", severity: issue.severity, text: L("permission.accessibility.missing"),
                        action: L("permission.openSystemSettings")
                    ) {
                        model.openPrivacySettings(.accessibility)
                    }
                case .accessibilityOptional:
                    IssueRow(
                        symbol: "accessibility", severity: issue.severity,
                        text: L("permission.accessibility.optional"), action: L("permission.openSystemSettings")
                    ) {
                        model.openPrivacySettings(.accessibility)
                    }
                case .notificationsDenied:
                    IssueRow(
                        symbol: "bell.slash", severity: issue.severity,
                        text: L("permission.notifications.denied"), action: L("permission.openSystemSettings")
                    ) {
                        model.openNotificationSettings()
                    }
                case .llmUnreachable:
                    if let failure = model.ask.lastFailure {
                        IssueRow(
                            symbol: "text.bubble", severity: issue.severity, text: failure.settingsText,
                            action: L("panel.ask.open")
                        ) {
                            openAskSettings()
                        }
                    }
                }
            }
        }
    }

    /// One issue, three situations: nothing to load, a choice to make, or a load that failed.
    private var modelText: LocalizedStringResource {
        if let failed = model.models.loadFailure {
            let name = ModelCatalog.entry(for: failed).displayName
            return L("panel.model.loadFailed \(name)")
        }
        return model.models.hasAnyInstalled ? L("panel.model.notChosen") : L("panel.model.missing")
    }
}

private struct IssueRow: View {
    let symbol: String
    let severity: HealthSeverity
    let text: LocalizedStringResource
    let action: LocalizedStringResource
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(severity.tint)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: perform) {
                Text(action)
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

extension HealthSeverity {
    /// Red for what stops dictation, orange for what only costs something, matching the menu bar icon.
    var tint: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .ok: .secondary
        }
    }
}

/// The config in force is still working; this says why the file on disk is not it, and where to look.
private struct ConfigErrorRow: View {
    let error: ConfigError
    let source: ConfigSource
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(HealthIssue.configInvalid.severity.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(source == .none ? L("panel.config.errorNoFallback") : L("panel.config.error"))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if let location = error.locationText {
                        Text(location).monospacedDigit() + Text(verbatim: " · ") + Text(error.problemText)
                    } else {
                        Text(error.problemText)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(action: reveal) {
                Text(L("panel.config.reveal"))
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

/// The most recent utterance, as its log line records it, with the one thing left to do about it.
struct LastView: View {
    let entry: LogEntry?
    let paste: PasteAction

    /// The Paste button's state, so LAST does not have to know about apps or the pipeline.
    struct PasteAction {
        /// False unless the text of the utterance just spoken is still the text on the clipboard.
        let isEnabled: Bool
        let isRunning: Bool
        let target: String?
        let perform: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            transcript
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)

            if let entry {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(entry.dotColor)
                        .frame(width: 6, height: 6)
                    Group {
                        if let ms = entry.shownMs, entry.isAsk {
                            // The model's time, in seconds: an answer takes seconds, a transcription milliseconds.
                            Text(entry.outcomeText)
                                + Text(
                                    verbatim: " · "
                                        + (Double(ms) / 1000).formatted(.number.precision(.fractionLength(1))) + " s")
                        } else if let ms = entry.shownMs {
                            Text(entry.outcomeText) + Text(verbatim: " · \(ms) ms")
                        } else {
                            Text(entry.outcomeText)
                        }
                    }
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help(Text(verbatim: entry.logDetail))

                if showsPasteHint(entry) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label {
                            Text(L("panel.last.pasteHint"))
                        } icon: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        if paste.isEnabled {
                            Spacer(minLength: 6)
                            pasteButton(paste)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 11)
    }

    /// Sends the text where the user was before they opened the panel, rather than making them ⌘V themselves.
    private func pasteButton(_ paste: PasteAction) -> some View {
        Button(action: paste.perform) {
            Group {
                if let target = paste.target {
                    Text(L("panel.last.pasteInto \(target)"))
                } else {
                    Text(L("panel.last.paste"))
                }
            }
            .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(paste.isRunning)
        .lineLimit(1)
    }

    @ViewBuilder private var transcript: some View {
        if let entry, entry.hidesTranscript {
            Label {
                Text(L("panel.transcript.concealed"))
            } icon: {
                Image(systemName: "lock")
            }
            .foregroundStyle(.secondary)
        } else if let raw = entry?.rawText, !raw.isEmpty {
            Text(verbatim: raw)
                .textSelection(.enabled)
        } else {
            Text(L("panel.transcript.placeholder"))
                .foregroundStyle(.secondary)
        }
    }

    /// Only for the utterance just spoken: an entry read back from the log after a relaunch may no longer be what
    /// the clipboard holds.
    private func showsPasteHint(_ entry: LogEntry) -> Bool {
        guard entry.id.hasPrefix(LogEntry.liveIDPrefix), case .copied = entry.outcome else { return false }
        return true
    }
}

/// Time, what was said, and how it ended, on one line. A row with text is a button that copies it.
struct RecentRow: View {
    let entry: LogEntry
    let justCopied: Bool
    let copy: (LogEntry) -> Void
    @State private var isHovering = false

    private var text: String? {
        guard let raw = entry.rawText, !raw.isEmpty else { return nil }
        return raw
    }

    /// A row with no text — a command, a discard, a password field — is not a button: a disabled one would dim
    /// the line and, worse, swallow the tooltip that is the only explanation it has.
    @ViewBuilder var body: some View {
        if text == nil {
            row.help(Text(entry.outcomeText))
        } else {
            Button {
                copy(entry)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            // Both: what the row says happened, and what clicking it does. The outcome is the only explanation
            // the coloured dot has, and becoming a button is no reason to lose it.
            .help(Text(entry.outcomeText) + Text(verbatim: " · ") + Text(L("panel.recent.copyHint")))
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.timestamp, format: .dateTime.hour().minute())
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Group {
                if let text {
                    Text(verbatim: text)
                } else {
                    Text(entry.outcomeText)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 6)
            if justCopied {
                Label {
                    Text(L("panel.recent.copied"))
                } icon: {
                    Image(systemName: "checkmark")
                }
                .foregroundStyle(.secondary)
                .fixedSize()
            } else {
                Circle()
                    .fill(entry.dotColor)
                    .frame(width: 6, height: 6)
                Text(entry.kindText)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .font(.system(size: 11))
        .contentShape(.rect)
        // Bleeds past the row's own bounds so the highlight has the same margins as the panel's other sections.
        .background {
            if isHovering, text != nil {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary)
                    .padding(.horizontal, -6)
                    .padding(.vertical, -3)
            }
        }
    }
}
