import HarkCore
import SwiftUI

/// An answer Hark computed (M13): the result, the working as read, the cells used and the checks. Read-only and
/// selectable, inside the answer's fill and cap, scrolling when the cells are unfolded.
struct AskExactAnswer: View {
    @Bindable var model: AskPanelModel
    let exact: ExactPresentation
    let cap: CGFloat
    @State private var showsRows = false
    @State private var height: CGFloat = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                resultLine
                if let working = exact.working {
                    workingLine(working)
                }
                fromLine
                if showsRows {
                    rows
                }
                checks
                if let note = model.layerNote {
                    AskLayerNoteLine(note: note)
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ExactHeightKey.self, value: proxy.size.height)
                })
        }
        .onPreferenceChange(ExactHeightKey.self) { measured in
            height = measured
        }
        .askScrollEdge()
        .scrollIndicators(height > cap ? .automatic : .never)
        .frame(height: min(max(height, 44), cap))
        .padding(6)
        .askFill(.background.opacity(reduceTransparency ? 1 : 0.6), minimum: AskGlass.innerRadius)
        .onAppear {
            // No window to show the cells on: the rows list them instead (plan §4.5).
            showsRows = model.opensRows || model.layerNote == .noWindow
        }
        .onChange(of: model.layerNote) { _, note in
            if note == .noWindow { showsRows = true }
        }
    }

    private var resultLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            (Text(verbatim: exact.result) + winner)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .optionalHelp(exact.exact.map { value in Text(L("ask.exact.exact \(value)")) })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(L("ask.exact.result.a11y \(exact.spokenResult)")))
                .optionalAccessibilityValue(exact.exact)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Label {
                Text(L("ask.exact.computed"))
            } icon: {
                Image(systemName: "function")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(Text(L("ask.exact.computed.help")))
        }
    }

    /// A pick's row after its figure, lighter: the figure is what Copy and Insert send.
    private var winner: Text {
        guard let row = exact.winner else { return Text(verbatim: "") }
        return Text(verbatim: " · " + row).fontWeight(.regular).foregroundStyle(.secondary)
    }

    private func workingLine(_ working: String) -> some View {
        Self.inWords(working)
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(3)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .help(Self.inWords(working))
            // An element of its own, as the result is: a label set on the selectable text itself sent a read of it
            // round between SwiftUI and AppKit until the stack ran out, as the answer came in (measured 2026-11-03).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.inWords(working))
            .accessibilityAddTraits(.isStaticText)
    }

    /// The cells used, the signs when the result both adds and subtracts, and the disclosure of the rows.
    private var fromLine: some View {
        HStack(spacing: 8) {
            Button {
                showsRows.toggle()
            } label: {
                Label {
                    if exact.showsSigns {
                        Text(L("ask.exact.cells \(exact.cellsUsed)")) + Text(verbatim: " · ")
                            + Text(L("ask.exact.signs \(exact.added) \(exact.subtracted)"))
                    } else {
                        Text(L("ask.exact.cells \(exact.cellsUsed)"))
                    }
                } icon: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showsRows ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(showsRows ? .isSelected : [])
            Spacer(minLength: 8)
            lensButton
        }
    }

    @ViewBuilder
    private var lensButton: some View {
        if model.lensAvailable != nil {
            let shown = model.lensShown
            Button {
                model.toggleLens()
            } label: {
                Text(shown ? L("ask.exact.hide") : L("ask.exact.show"))
            }
            .controlSize(.small)
            .askButtonStyle(prominent: false)
            .askAppearsActive()
            .disabled(model.lensAvailable == false || model.layerNote == .noWindow)
            .optionalHelp(model.lensAvailable == false ? Text(L("ask.exact.show.noDisplay")) : nil)
            .accessibilityLabel(Text(shown ? L("ask.exact.hide.a11y") : L("ask.exact.show.a11y")))
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(exact.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: Self.symbol(row.role))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(verbatim: row.text)
                        .monospacedDigit()
                    if !row.label.isEmpty {
                        Text(verbatim: row.label)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if row.uncertain {
                        Text(verbatim: "?")
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(row))
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var checks: some View {
        if let check = exact.understoodCheck {
            checkLine(Self.text(check))
        }
        ForEach(Array(exact.checks.enumerated()), id: \.offset) { _, warning in
            checkLine(Self.text(warning, named: exact.named))
        }
    }

    private func checkLine(_ text: Text) -> some View {
        Label {
            text
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        .font(.callout)
    }

    static func symbol(_ role: CellRole) -> String {
        switch role {
        case .added: "plus"
        case .subtracted: "minus"
        case .counted: "number"
        case .compared: "equal"
        case .rate: "multiply"
        }
    }

    static func roleWord(_ role: CellRole) -> LocalizedStringResource {
        switch role {
        case .added: L("ask.exact.role.added")
        case .subtracted: L("ask.exact.role.subtracted")
        case .counted: L("ask.exact.role.counted")
        case .compared: L("ask.exact.role.compared")
        case .rate: L("ask.exact.role.rate")
        }
    }

    /// "<role>, <text>, <label>", then whether it may be misread.
    static func spoken(_ row: ExactCellRow) -> Text {
        var text = Text(roleWord(row.role)) + Text(verbatim: ", " + row.text)
        if !row.label.isEmpty { text = text + Text(verbatim: ", " + row.label) }
        if row.uncertain { text = text + Text(verbatim: ", ") + Text(L("ask.exact.role.uncertain")) }
        return text
    }

    /// The working with its function names in words, as the panel shows it and VoiceOver reads it (the user's
    /// decision of 2026-11-05: « plus grand (38 ; 79,19) = », not MAX); − and × read as minus and times by themselves.
    static func inWords(_ working: String) -> Text {
        var text = Text(verbatim: "")
        var rest = Substring(working)
        while let match = rest.firstMatch(of: /\b(ARGMIN|ARGMAX|MIN|MAX|ROUND|COUNT|AVG)\(/) {
            text = text + Text(verbatim: String(rest[..<match.range.lowerBound]))
            text = text + Text(functionWord(String(match.output.1))) + Text(verbatim: " (")
            rest = rest[match.range.upperBound...]
        }
        return text + Text(verbatim: String(rest))
    }

    static func functionWord(_ name: String) -> LocalizedStringResource {
        switch name {
        case "MIN", "ARGMIN": L("ask.exact.fn.min")
        case "MAX", "ARGMAX": L("ask.exact.fn.max")
        case "ROUND": L("ask.exact.fn.round")
        case "COUNT": L("ask.exact.fn.count")
        default: L("ask.exact.fn.average")
        }
    }

    static func text(_ check: UnderstoodCheck) -> Text {
        switch check {
        case .spoken(let figure): Text(L("ask.exact.check.spoken \(figure)"))
        case .notRead(let figure): Text(L("ask.exact.check.summaryNumber \(figure)"))
        }
    }

    static func text(_ warning: MathWarning, named: [CellID: String]) -> Text {
        let cell = warning.cell.flatMap { named[$0] } ?? ""
        return switch warning {
        case .suspiciousCell: Text(L("ask.exact.check.uncertain"))
        case .doubt: Text(L("ask.exact.check.doubt \(cell)"))
        case .scaleMismatch: Text(L("ask.exact.check.scale \(cell)"))
        case .dashAsZero: Text(L("ask.exact.check.dash \(cell)"))
        case .parenthesized: Text(L("ask.exact.check.parenthesized \(cell)"))
        case .approximate: Text(L("ask.exact.check.approximate"))
        case .assumedConvention: Text(L("ask.exact.check.convention"))
        case .tie: Text(L("ask.exact.check.tie \(cell)"))
        case .rounded: Text(verbatim: "")
        }
    }
}

/// Several results, or a result numbered after an earlier one (M14, plan §4.4): one block per result in one scroll
/// area under the cap, "Computed by Hark" once. The number picks the block whose cells the layer shows.
struct AskExactResults: View {
    @Bindable var model: AskPanelModel
    let results: ExactResultsPresentation
    let cap: CGFloat
    @State private var height: CGFloat = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Kept free on the trailing side whether the scroller shows or not, so the text does not rewrap near the cap with
    /// overlay scrollers (Hark's default). With scroll bars always shown, the legacy scroller takes its own width once
    /// the content passes the cap: the text rewraps once, taller, so it stays past the cap and settles.
    static let scrollerReserve: CGFloat = 12

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Spacer(minLength: 8)
                        Label {
                            Text(L("ask.exact.computed"))
                        } icon: {
                            Image(systemName: "function")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(Text(L("ask.exact.computed.help")))
                    }
                    ForEach(Array(results.blocks.enumerated()), id: \.element.id) { position, block in
                        AskExactBlock(model: model, block: block, position: position)
                            .id(block.id)
                    }
                }
                .padding(5)
                .padding(.trailing, Self.scrollerReserve)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: ExactHeightKey.self, value: geometry.size.height)
                    })
            }
            .onChange(of: model.picked) { _, picked in
                guard let picked, let block = results.block(at: picked) else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(block.id) }
            }
        }
        .onPreferenceChange(ExactHeightKey.self) { measured in
            height = measured
        }
        .askScrollEdge()
        .scrollIndicators(height > cap ? .automatic : .never)
        .frame(height: min(max(height, 44), cap))
        .padding(6)
        .askFill(.background.opacity(reduceTransparency ? 1 : 0.6), minimum: AskGlass.innerRadius)
    }
}

/// Why the cells cannot show, or not all of them: one line under the answer or the block whose cells the layer holds.
struct AskLayerNoteLine: View {
    let note: LayerNote
    /// Show Cells is beside it, to try again with.
    var retries = true

    var body: some View {
        Label {
            note.text(retries: retries)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// One result's block: its number, then its figure, « Compris » line, working, cells and checks; or for a failed
/// result, a dash, its reason and its « Compris » line. Picked, it has a tint that changes no size.
struct AskExactBlock: View {
    @Bindable var model: AskPanelModel
    let block: ExactResultBlock
    let position: Int
    @State private var showsRows = false

    private var isPicked: Bool { model.picked == position }
    private var holdsLayer: Bool { model.layerBlock == position }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let exact = block.answer {
                computed(exact)
            } else {
                failed
            }
            if model.layerBlock == position, let note = model.layerNote {
                AskLayerNoteLine(note: note)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isPicked ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        // No window to show the cells on: the rows list them instead (plan §4.5), also when a pick makes this block
        // the holder while the note stays (it goes nil and back within one turn, which no change of the note shows).
        .onChange(of: holdsLayer && model.layerNote == .noWindow, initial: true) { _, lists in
            if lists { showsRows = true }
        }
    }

    /// The block's number, a button that picks it. ⌘ and the digit row pick it too, by the key's place: the panel reads
    /// them (`AskPanel.sendEvent`), as a shortcut bound to the character 1 misses AZERTY's « & » key (M14.7).
    @ViewBuilder
    private var numberButton: some View {
        if let number = block.number {
            let mark = Text(verbatim: ResultMark.circled(number))
                .font(.title2.weight(isPicked ? .bold : .regular))
                .foregroundStyle(isPicked ? Color.accentColor : Color.secondary)
            if block.isPickable {
                // No hint: the help says what a pick does, and only where it shows cells (c4 §7).
                Button {
                    model.pick(position)
                } label: {
                    mark
                }
                .buttonStyle(.plain)
                .optionalHelp(block.readsCells ? Text(L("ask.exact.pick.help")) : nil)
                .accessibilityLabel(Text(L("ask.exact.number.a11y \(number)")))
                .accessibilityAddTraits(isPicked ? .isSelected : [])
            } else {
                mark
                    .accessibilityLabel(Text(L("ask.exact.number.a11y \(number)")))
            }
        }
    }

    private func computed(_ exact: ExactPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                numberButton
                (Text(verbatim: exact.result) + winner(exact))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .optionalHelp(exact.exact.map { value in Text(L("ask.exact.exact \(value)")) })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(resultLabel(exact))
                    .optionalAccessibilityValue(exact.exact)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            if let understood = exact.understood {
                AskRestatement(text: understood)
            }
            if let working = exact.working {
                AskExactAnswer.inWords(working)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(AskExactAnswer.inWords(working))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(AskExactAnswer.inWords(working))
                    .accessibilityAddTraits(.isStaticText)
            }
            if block.readsCells, exact.cellsUsed > 0 {
                cellsLine(exact)
                if showsRows {
                    rows(exact)
                }
            }
            if let check = exact.understoodCheck {
                checkLine(AskExactAnswer.text(check))
            }
            ForEach(Array(exact.checks.enumerated()), id: \.offset) { _, warning in
                checkLine(AskExactAnswer.text(warning, named: exact.named))
            }
        }
    }

    private func resultLabel(_ exact: ExactPresentation) -> Text {
        guard let number = block.number else { return Text(L("ask.exact.result.a11y \(exact.spokenResult)")) }
        return Text(L("ask.exact.result.numbered.a11y \(number) \(exact.spokenResult)"))
    }

    private func winner(_ exact: ExactPresentation) -> Text {
        guard let row = exact.winner else { return Text(verbatim: "") }
        return Text(verbatim: " · " + row).fontWeight(.regular).foregroundStyle(.secondary)
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                numberButton
                Text(verbatim: "—")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if let failure = block.failure {
                    Text(failure.blockText(cellText: model.blockCellText(block)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(failedLabel(failure))
                }
                Spacer(minLength: 0)
                // Beside the reason that names the cell, so no row waits empty for it (M14.7).
                if block.readsCells {
                    lensButton
                }
            }
            if let understood = block.understood {
                AskRestatement(text: understood)
            }
        }
    }

    private func failedLabel(_ failure: MathFailure) -> Text {
        let reason = Text(failure.blockText(cellText: model.blockCellText(block)))
        guard let number = block.number else { return reason }
        return Text(L("ask.exact.failed.a11y \(number)")) + Text(verbatim: " ") + reason
    }

    private func cellsLine(_ exact: ExactPresentation) -> some View {
        HStack(spacing: 8) {
            Button {
                showsRows.toggle()
            } label: {
                Label {
                    if exact.showsSigns {
                        Text(L("ask.exact.cells \(exact.cellsUsed)")) + Text(verbatim: " · ")
                            + Text(L("ask.exact.signs \(exact.added) \(exact.subtracted)"))
                    } else {
                        Text(L("ask.exact.cells \(exact.cellsUsed)"))
                    }
                } icon: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showsRows ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(showsRows ? .isSelected : [])
            Spacer(minLength: 8)
            lensButton
        }
    }

    /// Show/Hide Cells, on the block whose cells the layer holds: the picked one, or the last picked that read cells
    /// when the pick reads none. Its slot keeps its size on every block, so a pick moves nothing.
    private var lensButton: some View {
        let shown = model.lensShown
        return Button {
            model.toggleLens()
        } label: {
            Text(shown ? L("ask.exact.hide") : L("ask.exact.show"))
        }
        .controlSize(.small)
        .askButtonStyle(prominent: false)
        .askAppearsActive()
        .disabled(model.lensAvailable != true || model.layerNote == .noWindow)
        .optionalHelp(model.lensAvailable == false ? Text(L("ask.exact.show.noDisplay")) : nil)
        .opacity(holdsLayer ? 1 : 0)
        .allowsHitTesting(holdsLayer)
        .accessibilityHidden(!holdsLayer)
        .accessibilityLabel(Text(shown ? L("ask.exact.hide.a11y") : L("ask.exact.show.a11y")))
    }

    private func rows(_ exact: ExactPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(exact.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: AskExactAnswer.symbol(row.role))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(verbatim: row.text)
                        .monospacedDigit()
                    if !row.label.isEmpty {
                        Text(verbatim: row.label)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if row.uncertain {
                        Text(verbatim: "?")
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AskExactAnswer.spoken(row))
            }
        }
        .padding(.leading, 4)
    }

    private func checkLine(_ text: Text) -> some View {
        Label {
            text
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        .font(.callout)
    }
}

private struct ExactHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// A tooltip only when there is one to show.
    @ViewBuilder
    fileprivate func optionalHelp(_ text: Text?) -> some View {
        if let text { help(text) } else { self }
    }

    /// An accessibility value only when there is one: a block's exact figure when rounding changed it (c4 §7).
    @ViewBuilder
    fileprivate func optionalAccessibilityValue(_ value: String?) -> some View {
        if let value { accessibilityValue(Text(verbatim: value)) } else { self }
    }
}
