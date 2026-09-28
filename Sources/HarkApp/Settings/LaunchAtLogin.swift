import Foundation
import Observation
import ServiceManagement
import os

/// SMAppService.mainApp. Off until the user turns it on; failures are shown, not swallowed.
@Observable
final class LaunchAtLogin {
    private(set) var status = SMAppService.mainApp.status
    private(set) var failure: String?

    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "login-item")

    var isOn: Bool {
        status == .enabled || status == .requiresApproval
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failure = nil
        } catch {
            failure = error.localizedDescription
            Self.logger.error("login item \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
    }
}
