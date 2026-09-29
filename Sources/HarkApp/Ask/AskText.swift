import HarkCore
import SwiftUI

/// What Settings › Ask, the panel and the Ask panel say about an LLM call that failed, in the user's language. The
/// server's own message is shown as it wrote it.
extension LLMFailure {
    /// Settings › Ask: the problem, and what to do about it with the Test button there.
    var settingsText: LocalizedStringResource {
        switch self {
        case .notRunning(let endpoint): L("settings.ask.failure.notRunning \(endpoint)")
        case .keyRefused: L("settings.ask.failure.keyRefused")
        case .noKey: L("settings.ask.failure.noKey")
        default: sharedText
        }
    }

    /// The menu bar panel's row and status tooltip: the problem alone. Settings' "test again" has no Test button there.
    var panelText: LocalizedStringResource {
        switch self {
        case .notRunning(let endpoint): L("panel.ask.failure.notRunning \(endpoint)")
        default: settingsText
        }
    }

    /// The Ask panel: the problem and what to do about it, with Retry beside it.
    var popupText: LocalizedStringResource {
        switch self {
        case .notRunning(let endpoint): L("ask.failure.notRunning \(endpoint)")
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
        case .notRunning, .keyRefused, .noKey: L("ask.failure.noAnswer")
        }
    }
}
