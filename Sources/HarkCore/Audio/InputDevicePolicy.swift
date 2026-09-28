import Foundation

public enum InputDeviceWarning: Sendable, Equatable {
    /// The device the user picked is not attached; a fallback is in use.
    case preferredDeviceMissing
    /// Always-on is holding a Bluetooth mic open, which degrades the headset's output audio and drains it.
    case bluetoothWhileAlwaysOn
}

public struct InputDeviceChoice: Sendable, Equatable {
    public let device: AudioInputDevice
    public let warning: InputDeviceWarning?

    public init(device: AudioInputDevice, warning: InputDeviceWarning? = nil) {
        self.device = device
        self.warning = warning
    }
}

/// Picks the capture device. Push-to-talk follows the system input, AirPods included, because the mic is open for
/// seconds; always-on defaults to the built-in mic because holding a Bluetooth mic open degrades the headset.
public struct InputDevicePolicy: Sendable, Equatable {
    /// nil follows the system default input.
    public var preferredUID: String?
    public var preferBuiltInWhenAlwaysOn: Bool

    private static let bluetooth: Set<AudioTransport> = [.bluetooth, .bluetoothLE]

    public init(preferredUID: String? = nil, preferBuiltInWhenAlwaysOn: Bool = true) {
        self.preferredUID = preferredUID
        self.preferBuiltInWhenAlwaysOn = preferBuiltInWhenAlwaysOn
    }

    public func choose(from devices: [AudioInputDevice], systemDefault: UInt32?, mode: CaptureMode)
        -> InputDeviceChoice?
    {
        guard let first = devices.first else { return nil }
        let preferred = preferredUID.flatMap { uid in devices.first { $0.uid == uid } }
        let builtIn = devices.first { $0.transport == .builtIn }
        let systemInput = systemDefault.flatMap { id in devices.first { $0.id == id } }
        let fallback = systemInput ?? builtIn ?? first

        let device: AudioInputDevice
        switch mode {
        case .pushToTalk:
            device = preferred ?? fallback
        case .alwaysOn:
            device = preferred ?? (preferBuiltInWhenAlwaysOn ? builtIn : nil) ?? fallback
        }

        let warning: InputDeviceWarning? =
            if preferredUID != nil && preferred == nil {
                .preferredDeviceMissing
            } else if mode == .alwaysOn && Self.bluetooth.contains(device.transport) {
                .bluetoothWhileAlwaysOn
            } else {
                nil
            }
        return InputDeviceChoice(device: device, warning: warning)
    }
}
