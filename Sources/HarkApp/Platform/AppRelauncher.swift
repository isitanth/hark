import AppKit
import Foundation
import os

/// Quits through the normal path and opens Hark again once this process is gone. A second instance started while
/// this one still runs would only be brought forward, so a detached shell waits on our pid before `open`.
enum AppRelauncher {
    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "lifecycle")

    static func relaunch() {
        let helper = Process()
        helper.executableURL = URL(filePath: "/bin/sh")
        helper.arguments = [
            "-c", #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open "$2""#,
            "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path,
        ]
        do {
            try helper.run()
        } catch {
            logger.error("the relaunch helper did not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApplication.shared.terminate(nil)
    }
}
