import AppKit
import SwiftUI

/// What Hark is, which build this is, and what the dots in RECENT and the Log tab mean (the user's request of
/// 2026-09-28). The colours are the ones `LogEntry.dotColor` gives the rows (EntryText.swift), in the same order.
struct AboutSettingsView: View {
    private struct Dot: Identifiable {
        let id: Int
        let color: Color
        let title: LocalizedStringResource
        let meaning: LocalizedStringResource
    }

    private static let dots: [Dot] = [
        Dot(id: 0, color: .blue, title: L("settings.about.dot.blue"), meaning: L("settings.about.dot.blue.meaning")),
        Dot(
            id: 1, color: .orange, title: L("settings.about.dot.orange"),
            meaning: L("settings.about.dot.orange.meaning")),
        Dot(
            id: 2, color: .green, title: L("settings.about.dot.green"),
            meaning: L("settings.about.dot.green.meaning")),
        Dot(
            id: 3, color: .secondary, title: L("settings.about.dot.grey"),
            meaning: L("settings.about.dot.grey.meaning")),
        Dot(id: 4, color: .red, title: L("settings.about.dot.red"), meaning: L("settings.about.dot.red.meaning")),
    ]

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .frame(width: 48, height: 48)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "Hark")
                                .font(.title2.weight(.semibold))
                            Text(L("settings.about.version \(version) \(build)"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(Self.dots) { dot in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle()
                                .fill(dot.color)
                                .frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dot.title)
                                Text(dot.meaning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Text(L("settings.about.dots.hover"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text(L("settings.about.dots"))
                }
            }
            .formStyle(.grouped)

            Text(L("settings.about.footer"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(height: 560)
    }
}
