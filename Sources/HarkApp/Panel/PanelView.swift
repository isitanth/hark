import AppKit
import HarkCore
import SwiftUI

/// The design brief's panel: header with the state pill and "device · model", the standing problems, LAST with its
/// Paste button, RECENT whose rows copy on click, and the footer.
struct PanelView: View {
    static let previewWindowID = "panel-preview"

    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    /// The window this panel is in: the menu bar extra's, or the preview window's. Paste closes it, rather than
    /// whichever window happens to be key.
    @State private var window: NSWindow?
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if !model.health.issues.isEmpty {
                HealthRows(
                    model: model, openModelSettings: { showSettings(.model) },
                    openAskSettings: { showSettings(.ask) }
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                Divider()
            }

            SectionTitle(L("panel.section.last"))
            LastView(entry: model.feed.last, paste: pasteAction)

            if !model.feed.recent.isEmpty {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(L("panel.section.recent"))
                    Spacer()
                    Button {
                        confirmingClear = true
                    } label: {
                        Text(L("panel.recent.clear"))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                }
                RecentList(entries: model.feed.recent, copiedID: model.copiedEntryID, copy: model.copyToClipboard)
                    .padding(.bottom, 8)
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            fit(height: $0)
        }
        .clearHistoryConfirmation(isPresented: $confirmingClear) {
            model.clearHistory()
            window?.close()
        }
        .background(PanelWindowReader { window = $0 })
        .onAppear {
            model.refreshPermissions()
            model.refreshInputDevices()
            if let profile = model.config.config.effectiveLLM.activeProfile {
                Task { await model.ask.checkOnOpen(profile) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "Hark")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Text(stateText)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            HStack(spacing: 4) {
                Text(deviceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "·")
                Text(modelName)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The button under LAST, named after the app it would paste into when that app has a name.
    private var pasteAction: LastView.PasteAction {
        let entry = model.feed.last
        return LastView.PasteAction(
            isEnabled: model.canPasteLast, isRunning: model.isPasting,
            target: model.previousApp.flatMap { $0.name ?? $0.bundleID.map(AppNames.name(for:)) },
            perform: {
                guard let entry else { return }
                model.pasteLast(entry, dismiss: { window?.close() })
            })
    }

    /// The icon groups every step after recording as transcribing; the pill can say which one.
    private var stateText: LocalizedStringResource {
        switch model.snapshot.phase {
        case .inserting: L("state.inserting")
        case .copying: L("state.copying")
        default: model.iconState.label
        }
    }

    private var deviceName: AttributedString {
        guard let device = model.inputChoice?.device else {
            return AttributedString(localized: L("panel.header.noInput"))
        }
        return AttributedString(device.name)
    }

    private var modelName: AttributedString {
        guard let tier = model.models.loadedTier else {
            return AttributedString(localized: L("panel.header.noModel"))
        }
        return AttributedString(ModelCatalog.entry(for: tier).displayName)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                showSettings(.commands)
            } label: {
                Text(L("panel.commands"))
            }
            Button {
                showSettings()
            } label: {
                Text(L("panel.settings"))
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text(L("panel.quit"))
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The menu bar extra's window grows with its content and never shrinks while open: a health row gone after a
    /// successful Test, RECENT cleared, a shorter LAST (seen 2026-09-28) left the content centred between empty,
    /// see-through strips. The window follows the content's height instead, its top edge kept under the menu bar.
    private func fit(height: CGFloat) {
        guard let window, height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(content.height - height) > 0.5 else { return }
        let fitted = NSRect(x: content.minX, y: content.maxY - height, width: content.width, height: height)
        window.setFrame(window.frameRect(forContentRect: fitted), display: true)
    }

    private func showSettings(_ tab: SettingsTab? = nil) {
        if let tab { model.settingsTab = tab }
        openSettings()
        NSApplication.shared.activate()
    }
}

/// RECENT: `RecentFeed.visibleRows` rows tall, newest first, the rest a scroll away.
private struct RecentList: View {
    static let rowHeight: CGFloat = 16
    static let spacing: CGFloat = 6
    /// Room for a row's hover highlight, which bleeds 3 pt above and below it, inside the scroll's clip.
    static let inset: CGFloat = 3
    let entries: [LogEntry]
    let copiedID: String?
    let copy: (LogEntry) -> Void

    var body: some View {
        let shown = CGFloat(min(entries.count, RecentFeed.visibleRows))
        ScrollView {
            VStack(alignment: .leading, spacing: Self.spacing) {
                ForEach(entries) { entry in
                    RecentRow(entry: entry, justCopied: copiedID == entry.id, copy: copy)
                        .frame(height: Self.rowHeight)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, Self.inset)
        }
        .frame(height: shown * Self.rowHeight + max(shown - 1, 0) * Self.spacing + 2 * Self.inset)
        .scrollDisabled(entries.count <= RecentFeed.visibleRows)
    }
}

private struct SectionTitle: View {
    let title: LocalizedStringResource

    init(_ title: LocalizedStringResource) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 4)
    }
}

/// Hands the panel's window to the view, once it is in a hierarchy.
private struct PanelWindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        found(window)
    }
}
