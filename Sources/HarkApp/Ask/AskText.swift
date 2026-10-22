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
