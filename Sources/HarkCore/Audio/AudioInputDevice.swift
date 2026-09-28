import Foundation

public enum AudioTransport: String, Sendable, CaseIterable {
    case builtIn
    case usb
    case bluetooth
    case bluetoothLE
    case continuity
    case aggregate
    case virtual
    case airPlay
    case other
}

/// An input-capable Core Audio device.
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    /// Core Audio object ID (`AudioDeviceID`). Only valid while the device is attached.
    public let id: UInt32
    /// `kAudioDevicePropertyDeviceUID`: stable across replugs and reboots. This is what preferences store.
    public let uid: String
    public let name: String
    public let transport: AudioTransport

    public init(id: UInt32, uid: String, name: String, transport: AudioTransport) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
    }
}

public enum CaptureMode: Sendable, Equatable {
    case pushToTalk
    case alwaysOn
}
