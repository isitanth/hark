import HarkCore
import SwiftUI
import UniformTypeIdentifiers

/// The Commands tab: the apps you can open by voice. commands.yaml stays the source of truth: a change here rewrites
/// the whole file through `ConfigStore`, based on the snapshot the change was made against, and the list shows what
/// the store read back.
struct CommandsSettingsView: View {
    let model: AppModel
    @State private var selection: Set<String> = []
    @State private var editing: Editing?
    @State private var status: Status?
    /// The app a Test is opening, while it runs.
    @State private var testing: String?
    @State private var busy = false
    @State private var sheets = 0

    private struct Row: Identifiable {
        let entry: CommandEntry
        var id: String { entry.id }
    }

    /// The sheet on show, and the config it was opened on. Its save is based on that snapshot, so a change made to the
    /// file meanwhile — a command edited or deleted in a text editor — comes back as a conflict instead of being
    /// merged away. After a conflict it is re-based on the file as it is now, under the same `id`, so the sheet keeps
    /// what was typed and a second Save applies it on top.
    private struct Editing: Identifiable {
        let id: Int
        let original: CommandEntry?
        let snapshot: ConfigSnapshot
    }

    /// What the last Test or change came to, under the buttons.
    private struct Status {
        let text: LocalizedStringResource
        let isProblem: Bool
    }

    private var snapshot: ConfigSnapshot { model.config }
    private var commands: [CommandEntry] { snapshot.config.commands }
    /// Deleted, or unreadable: nobody is editing it, so writing it again from the commands in force loses nothing.
    private var fileMissing: Bool { snapshot.isDegraded && snapshot.diskRevision == nil }
    /// A file with an error runs on its last good copy; writing that copy back would erase whatever the user was fixing.
    /// The store refuses such a write as well, whatever the view thinks.
    private var broken: Bool { snapshot.isDegraded && !fileMissing }
    private var editable: Bool { !broken && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("settings.commands.help"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if snapshot.isDegraded {
                Label {
                    if fileMissing {
                        Text(L("settings.commands.missing"))
                    } else if snapshot.source == .none {
                        Text(L("settings.commands.degradedNone"))
                    } else {
                        Text(L("settings.commands.degraded"))
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .fixedSize(horizontal: false, vertical: true)
                if let error = snapshot.error {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Group {
                            if let location = error.locationText {
                                Text(location).monospacedDigit() + Text(verbatim: " · ") + Text(error.problemText)
                            } else {
                                Text(error.problemText)
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        Spacer()
                        Button {
                            model.revealCommandsFile()
                        } label: {
                            Text(L("settings.commands.reveal"))
                        }
                        .controlSize(.small)
                    }
                }
            }
            table
            buttons
            if let testing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("settings.commands.testing \(testing)"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let status {
                Label {
                    Text(status.text)
                } icon: {
                    Image(systemName: status.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(status.isProblem ? .orange : .green)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            words
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L("settings.commands.commentsLost"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    model.revealCommandsFile()
                } label: {
                    Text(L("settings.commands.reveal"))
                }
            }
        }
        .padding(20)
        .frame(minHeight: 480)
        // A row that left the file, through a text editor or a remove, is not selected any more, and a Test that
        // worked is about a list that is gone. A problem stays: a conflict reloads the file, and that reload lands
        // here right after the message saying so. The next Test or change clears it.
        .onChange(of: commands.map(\.id)) { _, ids in
            selection.formIntersection(ids)
            if status?.isProblem == false { status = nil }
        }
        .sheet(item: $editing) { editing in
            CommandEditor(
                original: editing.original, config: editing.snapshot.config,
                taken: Set(editing.snapshot.config.commands.map(\.id)), degraded: broken
            ) { entry in
                await save(entry, from: editing)
            }
        }
    }

    private var table: some View {
        Table(commands.map { Row(entry: $0) }, selection: $selection) {
            TableColumn(Text(L("settings.commands.column.app"))) { row in
                Text(verbatim: row.entry.app)
            }
            TableColumn(Text(L("settings.commands.column.aliases"))) { row in
                Text(verbatim: row.entry.aliases.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            TableColumn(Text(verbatim: "")) { row in
                let app = row.entry.app
                Button {
                    test(row.entry)
                } label: {
                    Text(L("settings.commands.test"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
                .accessibilityLabel(Text(L("settings.commands.test.label \(app)")))
            }
            .width(84)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button {
                edit(ids)
            } label: {
                Text(L("settings.commands.edit"))
            }
            .disabled(ids.count != 1 || !editable)
            Button {
                remove(ids)
            } label: {
                Text(L("settings.commands.remove"))
            }
            .disabled(ids.isEmpty || !editable)
        } primaryAction: { ids in
            edit(ids)
        }
        .onDeleteCommand { remove(selection) }
        .overlay {
            // A broken file already says, above, why there is nothing here.
            if commands.isEmpty && !broken {
                Text(L("settings.commands.empty"))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 210)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button {
                add()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(Text(L("settings.commands.add")))
            .help(Text(L("settings.commands.add")))
            .disabled(!editable)
            Button {
                remove(selection)
            } label: {
                Image(systemName: "minus")
            }
            .accessibilityLabel(Text(L("settings.commands.remove")))
            .help(Text(L("settings.commands.remove")))
            .disabled(selection.isEmpty || !editable)
            Button {
                edit(selection)
            } label: {
                Text(L("settings.commands.edit"))
            }
            .disabled(selection.count != 1 || !editable)
        }
    }

    /// The verbs and the skipped words, read-only: they are edited in the file.
    @ViewBuilder private var words: some View {
        let verbs = Self.joined(snapshot.config.openVerbs)
        if verbs.isEmpty {
            Label {
                Text(L("settings.commands.noVerbs"))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            LabeledContent {
                Text(verbatim: verbs)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text(L("settings.commands.verbs"))
            }
        }
        LabeledContent {
            Text(verbatim: Self.joined(snapshot.config.fillers))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(L("settings.commands.fillers"))
        }
    }

    private static func joined(_ lists: [String: [String]]) -> String {
        lists.keys.sorted().flatMap { lists[$0] ?? [] }.joined(separator: ", ")
    }

    private func add() {
        guard editable else { return }
        sheets += 1
        editing = Editing(id: sheets, original: nil, snapshot: snapshot)
    }

    private func edit(_ ids: Set<String>) {
        guard editable, ids.count == 1, let entry = commands.first(where: { ids.contains($0.id) }) else { return }
        sheets += 1
        editing = Editing(id: sheets, original: entry, snapshot: snapshot)
    }

    /// Only rows the file still has: a selection can outlive a row that a text editor removed.
    private func remove(_ ids: Set<String>) {
        let base = snapshot
        let doomed = ids.intersection(base.config.commands.map(\.id))
        guard editable, !doomed.isEmpty else { return }
        let kept = base.config.commands.filter { !doomed.contains($0.id) }
        Task {
            if let problem = await write(kept, basedOn: base) {
                show(Status(text: problem.text, isProblem: true))
            } else {
                selection.subtract(doomed)
            }
        }
    }

    private func save(_ entry: CommandEntry, from sheet: Editing) async -> LocalizedStringResource? {
        var next = sheet.snapshot.config.commands
        if let original = sheet.original, let index = next.firstIndex(where: { $0.id == original.id }) {
            next[index] = entry
        } else {
            next.append(entry)
        }
        let problem = await write(next, basedOn: sheet.snapshot)
        if case .conflict = problem {
            // The store has read the file again. What the command is there now, if anything, is the new original.
            let current = model.config
            let original = sheet.original.flatMap { original in current.config.commands.first { $0.id == original.id } }
            editing = Editing(id: sheet.id, original: original, snapshot: current)
        }
        return problem?.text
    }

    /// Nil once commands.yaml holds `next`, or when `next` changes nothing, so the file and its comments stay as they
    /// are; otherwise what stopped it.
    private func write(_ next: [CommandEntry], basedOn base: ConfigSnapshot) async -> ConfigWriteError? {
        guard next != base.config.commands else { return nil }
        busy = true
        defer { busy = false }
        status = nil
        return await model.saveCommands(next, basedOn: base)
    }

    private func test(_ entry: CommandEntry) {
        guard !busy else { return }
        busy = true
        status = nil
        let app = entry.app
        testing = app
        Task {
            let failure = await model.run(entry)
            busy = false
            testing = nil
            show(
                failure.map { Status(text: Self.text(for: $0, app: app), isProblem: true) }
                    ?? Status(text: L("settings.commands.tested \(app)"), isProblem: false))
        }
    }

    private func show(_ status: Status) {
        self.status = status
        AccessibilityNotification.Announcement(String(localized: status.text)).post()
    }

    private static func text(for failure: PipelineFailure, app name: String) -> LocalizedStringResource {
        switch failure {
        case .appNotFound(let app):
            return L("settings.commands.tested.notFound \(app)")
        case .appNotActivated(let app):
            return L("settings.commands.tested.behind \(app)")
        case .appExited(let app):
            return L("settings.commands.tested.exited \(app)")
        case .actionLaunch:
            return L("settings.commands.tested.refused")
        case .actionTimeout:
            let seconds = Int(ActionRunner.defaultDeadline.components.seconds)
            return L("settings.commands.tested.timeout \(name) \(seconds)")
        default:
            let code = failure.code
            return L("settings.commands.tested.failed \(code)")
        }
    }
}

/// Adds a command or edits one: the app, by name or picked on disk, and the other names it answers to. It sizes to
/// what it says, so the line under the app never pushes the rest out of sight.
private struct CommandEditor: View {
    let original: CommandEntry?
    /// The config the command joins, for the fillers a name must not consist of.
    let config: CommandConfig
    let taken: Set<String>
    let degraded: Bool
    let save: (CommandEntry) async -> LocalizedStringResource?
    @Environment(\.dismiss) private var dismiss
    @State private var app: String
    @State private var aliases: String
    @State private var problem: LocalizedStringResource?
    @State private var picking = false
    @State private var saving = false
    private let locator = ApplicationLocator()

    init(
        original: CommandEntry?, config: CommandConfig, taken: Set<String>, degraded: Bool,
        save: @escaping (CommandEntry) async -> LocalizedStringResource?
    ) {
        self.original = original
        self.config = config
        self.taken = taken
        self.degraded = degraded
        self.save = save
        _app = State(initialValue: original?.app ?? "")
        _aliases = State(initialValue: original?.aliases.joined(separator: ", ") ?? "")
    }

    private var trimmedApp: String {
        app.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What makes the draft unusable before any YAML is written for it, so the message is about the command.
    private var draftProblem: CommandDraftProblem? {
        guard !trimmedApp.isEmpty else { return nil }
        return CommandEntry.problems(
            app: trimmedApp, aliases: CommandEntry.aliases(from: aliases), in: config, editing: original?.id
        ).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? L("settings.commands.editor.add") : L("settings.commands.editor.edit"))
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text(L("settings.commands.column.app"))
                        .gridColumnAlignment(.trailing)
                    HStack {
                        TextField(text: $app, prompt: Text(verbatim: "Safari")) {
                            Text(L("settings.commands.column.app"))
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        Button {
                            picking = true
                        } label: {
                            Text(L("settings.commands.editor.choose"))
                        }
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    found
                }
                GridRow {
                    Text(L("settings.commands.column.aliases"))
                    TextField(text: $aliases, prompt: Text(verbatim: "réglages, settings")) {
                        Text(L("settings.commands.column.aliases"))
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                }
                .padding(.top, 8)
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(L("settings.commands.editor.aliasesHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if degraded {
                notice(L("settings.commands.brokenFile"), color: .orange)
            } else if let draftProblem {
                notice(Self.text(for: draftProblem), color: .orange)
            } else if let problem {
                notice(problem, color: .red)
            }
            HStack {
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text(L("settings.commands.editor.cancel"))
                }
                .keyboardShortcut(.cancelAction)
                // A save in flight finishes in the sheet, so its answer has somewhere to go.
                .disabled(saving)
                Button {
                    commit()
                } label: {
                    Text(L("settings.commands.editor.save"))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedApp.isEmpty || saving || degraded || draftProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.application]) { result in
            if case .success(let url) = result { app = locator.name(for: url) }
        }
    }

    /// Where the name leads on this Mac, as it is typed; what to type while it is empty.
    @ViewBuilder private var found: some View {
        if trimmedApp.isEmpty {
            Text(L("settings.commands.editor.appHelp"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let url = locator.url(for: trimmedApp) {
            Text(verbatim: ApplicationLocator.path(of: url))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label {
                Text(L("settings.commands.editor.notFound"))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "questionmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private func notice(_ text: LocalizedStringResource, color: Color) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(color)
        }
    }

    private func commit() {
        let entry = CommandEntry(
            id: original?.id ?? CommandEntry.newID(for: trimmedApp, taken: taken),
            action: original?.action ?? .openApp, app: trimmedApp, aliases: CommandEntry.aliases(from: aliases))
        saving = true
        Task {
            problem = await save(entry)
            saving = false
            if let problem {
                AccessibilityNotification.Announcement(String(localized: problem)).post()
            } else {
                dismiss()
            }
        }
    }

    private static func text(for problem: CommandDraftProblem) -> LocalizedStringResource {
        switch problem {
        case .appUnsayable:
            return L("settings.commands.editor.appUnsayable")
        case .aliasUnsayable(let alias):
            return L("settings.commands.editor.aliasUnsayable \(alias)")
        case .onlyFillers(let words):
            return L("settings.commands.editor.onlyFillers \(words)")
        case .collision(let typed, let otherApp):
            return L("settings.commands.editor.collision \(typed) \(otherApp)")
        }
    }
}

extension ConfigWriteError {
    /// Why the Settings UI could not write commands.yaml, in the user's language. A collision is said in terms of the
    /// command, since the line it names belongs to text Hark generated, not to the file on disk.
    var text: LocalizedStringResource {
        switch self {
        case .conflict:
            return L("settings.commands.conflict")
        case .degraded:
            return L("settings.commands.brokenFile")
        case .invalid(let error):
            if case .collision(let normalized, _, _, _) = error.problem {
                return L("settings.commands.editor.collision \(normalized)")
            }
            return error.problemText
        case .io(let errno):
            let code = Int(errno)
            return L("settings.commands.writeFailed \(code)")
        }
    }
}
