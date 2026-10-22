import CoreGraphics
import Foundation

/// Screen Recording, asked when the user first frames a region, never at launch. macOS reads the grant when the
/// process starts, so one given in System Settings counts only after a relaunch.
public enum ScreenRecordingPermission {
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system alert the first time, then nothing: the user goes to System Settings. Returns the current
    /// grant.
    @discardableResult
    public static func request() -> Bool { CGRequestScreenCaptureAccess() }
}
