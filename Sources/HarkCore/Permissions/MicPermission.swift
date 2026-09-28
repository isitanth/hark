import AVFoundation
import Foundation

public enum MicPermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case undetermined
}

public enum MicPermission {
    public static var status: MicPermissionStatus {
        status(for: AVAudioApplication.shared.recordPermission)
    }

    /// Shows the system prompt only while the status is undetermined; otherwise returns the stored answer.
    public static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static func status(for permission: AVAudioApplication.recordPermission) -> MicPermissionStatus {
        switch permission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
    }
}
