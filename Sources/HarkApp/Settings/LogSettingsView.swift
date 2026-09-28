import AppKit
import HarkCore
import SwiftUI

/// The JSONL log, newest first, filtered by how each utterance ended. Read-only but for Clear History, which deletes
/// it after a confirmation (the user's decision of 2026-09-28).
struct LogSettingsView: View {
    let model: AppModel
    @State private var filter = LogFilter.all
    @State private var page = LogPage.empty
    @State private var confirmingClear = false

    /// Re-read when the filter changes, whenever the pipeline writes a line, and after a clear.
    private struct ReloadKey: Equatable {
        let filter: LogFilter
        let lastWritten: Date?
        let cleared: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $filter) {
                ForEach(LogFilter.allCases, id: \.self) { filter in
                    Text(Self.title(filter)).tag(filter)
                }
            } label: {
                Text(L("settings.log.filter"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            if page.entries.isEmpty {
                Text(L("settings.log.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(page.entries) { entry in
                    LogRow(entry: entry)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()
            HStack {
                if page.unreadableLines > 0 {
                    Label {
                        Text(L("settings.log.unreadable \(page.unreadableLines)"))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
                Spacer()
                Button {
                    confirmingClear = true
                } label: {
                    Text(L("history.clear.button"))
                }
                Button(action: reveal) {
                    Text(L("settings.log.reveal"))
                }
            }
            .padding(12)
        }
        .frame(height: 440)
        .clearHistoryConfirmation(isPresented: $confirmingClear, clear: model.clearHistory)
        .task(
            id: ReloadKey(
                filter: filter, lastWritten: model.snapshot.lastRecord?.timestamp, cleared: model.historyGeneration)
        ) {
            let reader = model.logReader
            let filter = filter
            page = await Task.detached { reader.read(filter: filter) }.value
        }
    }

    private func reveal() {
        if let file = model.logReader.newestFile() {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([model.paths.root])
        }
    }

    private static func title(_ filter: LogFilter) -> LocalizedStringResource {
        switch filter {
        case .all: L("settings.log.filter.all")
        case .commands: L("settings.log.filter.commands")
        case .text: L("settings.log.filter.text")
        case .errors: L("settings.log.filter.errors")
        }
    }
}

/// How it ended and when, then where, how long and which model, then what was said. The bundle ID and the error code
/// the words stand for are in the tooltip.
private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(entry.dotColor)
                    .frame(width: 6, height: 6)
                Text(entry.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(entry.outcomeText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)

            if !details.isEmpty {
                Text(verbatim: details.joined(separator: " · "))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 12)
            }

            if let text = entry.rawText, !text.isEmpty {
                Text(verbatim: text)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
            }
        }
        .padding(.vertical, 2)
        .help(Text(verbatim: entry.logDetail))
    }

    /// The app by name, the decode time, and the tier's catalogue name, which is a proper name in every language.
    /// An ask adds the model id that answered and its time from the request to the last token.
    private var details: [String] {
        var parts: [String] = []
        if let app = entry.appName { parts.append(app) }
        if let ms = entry.transcribeMs { parts.append("\(ms) ms") }
        if let tier = entry.modelTier.flatMap(ModelTier.init(rawValue:)) {
            parts.append(ModelCatalog.entry(for: tier).displayName)
        }
        let llm = [entry.llmModel, entry.llmMs.map { "\($0) ms" }].compactMap(\.self)
        if !llm.isEmpty { parts.append(llm.joined(separator: " ")) }
        return parts
    }
}
