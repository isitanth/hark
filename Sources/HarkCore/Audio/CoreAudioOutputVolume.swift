import AudioToolbox
import CoreAudio
import Foundation

/// SystemOutputVolume over the HAL: the device's kAudioHardwareServiceDeviceProperty_VirtualMainVolume, output
/// scope, element main, which moves the main volume or the preferred channel pair with the balance kept.
public struct CoreAudioOutputVolume: SystemOutputVolume {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    public init() {}

    public func defaultOutputUID() -> String? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &id)
        guard status == noErr, id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return Self.uid(of: id)
    }

    public func volume(of uid: String) -> Float? {
        guard let id = Self.device(uid) else { return nil }
        return Self.readVolume(id)
    }

    public func isSettable(_ uid: String) -> Bool {
        guard let id = Self.device(uid) else { return false }
        var address = Self.volumeAddress
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    public func setVolume(_ volume: Float, of uid: String) -> Float? {
        guard let id = Self.device(uid) else { return nil }
        var address = Self.volumeAddress
        var value = Float32(min(max(volume, 0), 1))
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        guard status == noErr else { return nil }
        return Self.readVolume(id)
    }

    private static let volumeAddress = address(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func readVolume(_ id: AudioObjectID) -> Float? {
        var address = volumeAddress
        var size = UInt32(MemoryLayout<Float32>.size)
        var value: Float32 = 0
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, size == UInt32(MemoryLayout<Float32>.size) else { return nil }
        return value
    }

    /// kAudioHardwarePropertyTranslateUIDToDevice; a device that is gone translates to kAudioObjectUnknown.
    private static func device(_ uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice, scope: kAudioObjectPropertyScopeGlobal)
        var cfUID = uid as CFString
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        guard status == noErr, id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return id
    }

    /// The HAL returns string properties at +1.
    private static func uid(of id: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard let string = value?.takeRetainedValue(), status == noErr else { return nil }
        return string as String
    }
}
