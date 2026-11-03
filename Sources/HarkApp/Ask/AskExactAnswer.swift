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
            showsRows = model.opensRows
        }
    }

    private var resultLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: exact.result)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .optionalHelp(exact.exact.map { value in Text(L("ask.exact.exact \(value)")) })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(L("ask.exact.result.a11y \(exact.result)")))
                .accessibilityValue(Text(verbatim: exact.exact ?? exact.result))
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

    private func workingLine(_ working: String) -> some View {
        Text(verbatim: working)
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(3)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .help(working)
            // An element of its own, as the result is: a label set on the selectable text itself sent a read of it
            // round between SwiftUI and AppKit until the stack ran out, as the answer came in (measured 2026-11-03).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(working))
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
            .disabled(model.lensAvailable == false)
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

    /// The working with its function names in words; − and × read as minus and times by themselves.
    static func spoken(_ working: String) -> Text {
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
}
