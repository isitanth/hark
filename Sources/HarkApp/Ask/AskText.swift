import HarkCore
import SwiftUI

/// What Settings › Ask, the panel and the Ask panel say about an LLM call that failed, in the user's language. The
/// server's own message is shown as it wrote it.
extension LLMFailure {
    /// Settings › Ask: the problem, and what to do about it with the Test button there.
    var settingsText: LocalizedStringResource {
        switch self {
        case .notRunning(let endpoint): L("settings.ask.failure.notRunning \(endpoint)")
        case .unreachable(let host): L("settings.ask.failure.unreachable \(host)")
        case .keyRefused: L("settings.ask.failure.keyRefused")
        case .noKey: L("settings.ask.failure.noKey")
        default: sharedText
        }
    }

    /// The menu bar panel's row and status tooltip: the problem alone. Settings' "test again" has no Test button there.
    var panelText: LocalizedStringResource {
        switch self {
        case .notRunning(let endpoint): L("panel.ask.failure.notRunning \(endpoint)")
        case .unreachable(let host): L("panel.ask.failure.unreachable \(host)")
        default: settingsText
        }
    }

    /// The Ask panel: the problem and what to do about it, with Retry beside it.
    var popupText: LocalizedStringResource {
        switch self {
        case .notRunning(let endpoint): L("ask.failure.notRunning \(endpoint)")
        case .unreachable(let host): L("ask.failure.unreachable \(host)")
        case .keyRefused: L("ask.failure.keyRefused")
        case .noKey: L("ask.failure.noKey")
        default: sharedText
        }
    }

    private var sharedText: LocalizedStringResource {
        switch self {
        case .server(_, let message?): L("ask.failure.serverSaid \(message)")
        case .server(let status?, nil): L("ask.failure.status \(status)")
        case .server(nil, nil): L("ask.failure.streamError")
        case .noAnswer: L("ask.failure.noAnswer")
        case .empty: L("ask.failure.empty")
        case .refused: L("ask.failure.refused")
        case .notRunning, .unreachable, .keyRefused, .noKey: L("ask.failure.noAnswer")
        case .noVision(_, .needsMTPMode): L("ask.failure.visionNeedsMTP")
        case .noVision(let model?, _): L("ask.failure.noVision \(model)")
        case .noVision(nil, _): L("ask.failure.noVision.unnamed")
        case .profileChanged: L("ask.failure.profileChanged")
        case .frameMissing: L("ask.failure.regionFailed")
        case .formatRefused: L("ask.failure.refused")
        }
    }

    /// The Ask panel after an ask that carried an image: a refusal Hark cannot read as "no vision" names the image as
    /// the probable cause, with the server's own words.
    func popupText(imageAttached: Bool) -> LocalizedStringResource {
        if imageAttached, case .server(let status?, let message?) = self, (400..<500).contains(status) {
            return L("ask.failure.imageMaybe \(message)")
        }
        return popupText
    }
}

extension RegionFailure {
    /// The Ask panel: why the frame did not reach the model.
    var popupText: LocalizedStringResource {
        switch self {
        case .screenRecordingDenied: L("ask.failure.screenRecordingDenied")
        case .captureFailed: L("ask.failure.regionFailed")
        }
    }
}

extension MathFailure {
    /// The Ask panel: why the exact path stopped (M13). `cellText` is the failing cell's text as read, nil when the
    /// cell is not known.
    func popupText(cellText: String?) -> LocalizedStringResource {
        switch self {
        case .reader(.vision): L("ask.exact.failure.reader")
        case .reader(.timeout): L("ask.exact.failure.timeout")
        case .plan(.truncated): L("ask.exact.failure.truncated")
        case .plan(.unspokenConstant(let literal)): L("ask.exact.failure.constant \(literal)")
        case .plan(.unit): L("ask.exact.failure.unit")
        case .plan(.declaredUnit): L("ask.exact.failure.declaredUnit")
        case .plan(.percentScale): L("ask.exact.failure.percentScale")
        case .plan(.degenerate): L("ask.exact.failure.degenerate")
        case .plan(.json), .plan(.syntax), .plan(.unknownFunction), .plan(.unknownCell), .plan(.unknownResult),
            .plan(.noFormula):
            L("ask.exact.failure.plan")
        case .math(.noNumber, _):
            cellLine(cellText, empty: L("ask.exact.failure.noNumber.empty")) { text in
                L("ask.exact.failure.noNumber \(text)")
            }
        case .math(.garbled, _):
            cellLine(cellText, empty: L("ask.exact.failure.unreadCell")) { text in
                L("ask.exact.failure.garbled \(text)")
            }
        case .math(.divisionByZero, _): L("ask.exact.failure.zero")
        case .math(.overflow, _): L("ask.exact.failure.overflow")
        }
    }

    private func cellLine(
        _ text: String?, empty: LocalizedStringResource, named: (String) -> LocalizedStringResource
    ) -> LocalizedStringResource {
        guard let text else { return L("ask.exact.failure.unreadCell") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? empty : named(trimmed)
    }

    /// Whether `popupText` names a cell the layer outlines in red, so the popup may add that it is outlined (M14.7: not
    /// while a note says the cells cannot show).
    func outlinesCell(cellText: String?) -> Bool {
        guard let text = cellText?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        switch self {
        case .math(.noNumber, _): return true
        case .math(.garbled, _): return !text.isEmpty
        default: return false
        }
    }
}

extension FramingBlock {
    /// The listening panel, in place of the framing hint: why framing cannot work now.
    func text(requested: Bool) -> LocalizedStringResource {
        switch self {
        case .noScreenRecording: requested ? L("ask.framing.reopen") : L("ask.framing.noScreenRecording")
        case .modelCannotSee: L("ask.framing.modelCannotSee")
        case .framesFull: L("ask.framing.framesFull \(AskThread.maxFrames)")
        }
    }
}

extension MathFailure {
    /// A failed result's one line in its block (M14): no word of a red outline, the layer shows the cell on a pick.
    func blockText(cellText: String?) -> LocalizedStringResource {
        switch self {
        case .reader(.vision): L("ask.exact.failure.reader")
        case .reader(.timeout): L("ask.exact.failure.timeout")
        case .plan(.truncated): L("ask.exact.failed.truncated")
        case .plan(.unspokenConstant(let literal)): L("ask.exact.failed.constant \(literal)")
        case .plan(.unit): L("ask.exact.failed.unit")
        case .plan(.declaredUnit): L("ask.exact.failed.declaredUnit")
        case .plan(.percentScale): L("ask.exact.failed.percentScale")
        case .plan(.degenerate): L("ask.exact.failed.degenerate")
        case .plan(.json), .plan(.syntax), .plan(.unknownFunction), .plan(.unknownCell), .plan(.unknownResult),
            .plan(.noFormula):
            L("ask.exact.failed.plan")
        case .math(.noNumber, _):
            blockCellLine(cellText, empty: L("ask.exact.failed.noNumber.empty")) { text in
                L("ask.exact.failed.noNumber \(text)")
            }
        case .math(.garbled, _):
            blockCellLine(cellText, empty: L("ask.exact.failed.unreadCell")) { text in
                L("ask.exact.failed.garbled \(text)")
            }
        case .math(.divisionByZero, _): L("ask.exact.failed.zero")
        case .math(.overflow, _): L("ask.exact.failed.overflow")
        }
    }

    private func blockCellLine(
        _ text: String?, empty: LocalizedStringResource, named: (String) -> LocalizedStringResource
    ) -> LocalizedStringResource {
        guard let text else { return L("ask.exact.failed.unreadCell") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? empty : named(trimmed)
    }
}

extension LayerNote {
    /// The panel's one line under the block whose cells the layer holds: why the cells cannot show, or not all of them.
    /// Not found says that Show Cells tries again only where the button is (`retries`).
    func text(retries: Bool) -> Text {
        guard self == .notFound, retries else { return Text(text) }
        return Text(text) + Text(verbatim: " ") + Text(L("ask.layer.notFound.retry"))
    }

    private var text: LocalizedStringResource {
        switch self {
        case .noWindow: return L("ask.layer.noWindow")
        case .notFound: return L("ask.layer.notFound")
        case .outOfView(let visible, let total):
            let hidden = total - visible
            return L("ask.layer.outOfView \(hidden) \(total)")
        case .windowClosed: return L("ask.layer.windowClosed")
        case .otherScale: return L("ask.layer.otherScale")
        }
    }
}

extension ResultsAnnouncement {
    /// One sentence for every computed result (plan §4.4): "2 results: result 1, 89,67 €; result 2, 29,34 €", or the
    /// partial form when some failed, its list a sentence of its own. A lone numbered result reads as its block does,
    /// "Result 3: 1 076,04 €, computed by Hark". The items join with "; ", " ; " in French.
    func sentence(of total: Int) -> String {
        if count == total, total == 1, let item = items.first {
            let number = item.number
            let spoken = item.spoken
            return String(localized: L("ask.exact.result.numbered.a11y \(number) \(spoken)"))
        }
        let separator = String(localized: L("ask.exact.announce.separator"))
        let list = items.map { item in
            let number = item.number
            let spoken = item.spoken
            return String(localized: L("ask.exact.announce.item \(number) \(spoken)"))
        }.joined(separator: separator)
        guard count == total else {
            let sentence = list.prefix(1).localizedUppercase + list.dropFirst()
            return String(localized: L("ask.exact.announce.partial \(count) \(total) \(sentence)"))
        }
        return String(localized: L("ask.exact.announce.many \(count) \(list)"))
    }
}
