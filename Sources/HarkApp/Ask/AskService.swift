import AppKit
import HarkCore
import os

/// The Services menu's Ask Hark (Info.plist's NSServices, message `askHark`). AppKit calls it on the main thread with
/// the selection on a pasteboard, and activates Hark to do so (measured in M8.0). It returns at once, so the
/// service's timeout never applies: the ask itself runs after.
///
/// The provider cannot tell who called: inside the call, the frontmost app is Hark. The caller is the app that was in
/// front before Hark, which `AppModel.previousApp` tracks.
final class AskService: NSObject {
    /// What the service hands on: the selected text, never logged, and the app it came from.
    var onAsk: ((String, AppIdentity?) -> Void)?
    private let caller: () -> AppIdentity?

    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "ask")

    init(caller: @escaping () -> AppIdentity?) {
        self.caller = caller
    }

    @objc(askHark:userData:error:)
    func askHark(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let text = pasteboard.string(forType: .string) ?? ""
        let caller = caller()
        Self.logger.notice(
            "ask service: \(text.count, privacy: .public) characters from \(caller?.logName ?? "unknown", privacy: .public)"
        )
        onAsk?(text, caller)
    }
}
