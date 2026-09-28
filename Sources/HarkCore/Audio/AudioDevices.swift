import AudioToolbox
import CoreAudio
import Foundation
import os

public enum AudioDevices {
    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "audio-devices")
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Every device with at least one input stream (kAudioDevicePropertyStreams, input scope), in HAL order.
    public static func inputDevices() -> [AudioInputDevice] {
        guard let ids = readObjectIDs(system, kAudioHardwarePropertyDevices) else {
            logger.error("cannot list audio devices")
            return []
        }
        return ids.compactMap(inputDevice)
    }

    /// kAudioHardwarePropertyDefaultInputDevice; nil when there is none (kAudioObjectUnknown) or on error.
    public static func defaultInputDeviceID() -> UInt32? {
        guard let id = readUInt32(system, kAudioHardwarePropertyDefaultInputDevice),
            id != AudioObjectID(kAudioObjectUnknown)
        else { return nil }
        return id
    }

    /// One element whenever the set of devices or the default input changes (kAudioHardwarePropertyDevices and
    /// kAudioHardwarePropertyDefaultInputDevice). The listeners are removed when iteration stops.
    ///
    /// This uses the C-proc listener API, not AudioObjectAddPropertyListenerBlock: Swift imports the listener block
    /// type as a Swift closure and wraps it in a fresh ObjC block on every call, so the block passed to
    /// AudioObjectRemovePropertyListenerBlock never matches the registered one. The HAL answers noErr and keeps
    /// calling the listener. The proc variant identifies a listener by (proc, client data), which is stable.
    public static func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let listener = ChangeListener(continuation)
        let context = Unmanaged.passRetained(listener).toOpaque()
        var added: [AudioObjectPropertySelector] = []
        for selector in listenedSelectors {
            var address = propertyAddress(selector)
            let status = AudioObjectAddPropertyListener(system, &address, changeProc, context)
            if status == noErr {
                added.append(selector)
            } else {
                logger.error("cannot listen to audio hardware property \(selector): \(status)")
            }
        }
        let token = ListenerToken(context: context, selectors: added)
        continuation.onTermination = { _ in token.remove() }
        return stream
    }

    private static let listenedSelectors = [
        kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
    ]

    private static let changeProc: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        Unmanaged<ChangeListener>.fromOpaque(context).takeUnretainedValue().continuation.yield()
        return noErr
    }

    private final class ChangeListener: Sendable {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }

    /// Owns the +1 on the ChangeListener handed to the HAL as client data, released only after both listeners are
    /// removed. The raw pointer is only ever used as an identity and a release handle.
    private struct ListenerToken: @unchecked Sendable {
        let context: UnsafeMutableRawPointer
        let selectors: [AudioObjectPropertySelector]

        func remove() {
            for selector in selectors {
                var address = AudioDevices.propertyAddress(selector)
                let status = AudioObjectRemovePropertyListener(AudioDevices.system, &address, changeProc, context)
                if status != noErr {
                    AudioDevices.logger.error("cannot remove audio hardware listener \(selector): \(status)")
                }
            }
            Unmanaged<ChangeListener>.fromOpaque(context).release()
        }
    }

    /// Pure mapping of kAudioDevicePropertyTransportType values.
    public static func transport(forTransportType raw: UInt32) -> AudioTransport {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth: .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: .bluetoothLE
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            .continuity
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        default: .other
        }
    }

    /// Points an AUHAL (for example AVAudioEngine.inputNode.audioUnit) at a device via
    /// kAudioOutputUnitProperty_CurrentDevice, global scope, element 0.
    public static func setInputDevice(_ deviceID: UInt32, on unit: AudioUnit) -> OSStatus {
        var id = AudioDeviceID(deviceID)
        return AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
            UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// The device an AUHAL is currently bound to (kAudioOutputUnitProperty_CurrentDevice); nil on error.
    public static func currentDevice(of unit: AudioUnit) -> UInt32? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        guard status == noErr, id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return id
    }

    /// Name and UID are required; an unreadable transport type degrades to `.other` rather than hiding the device.
    private static func inputDevice(_ id: AudioObjectID) -> AudioInputDevice? {
        guard hasInputStreams(id) else { return nil }
        guard let uid = readString(id, kAudioDevicePropertyDeviceUID),
            let name = readString(id, kAudioObjectPropertyName)
        else {
            logger.error("skipping input device \(id): name or UID unreadable")
            return nil
        }
        let raw = readUInt32(id, kAudioDevicePropertyTransportType) ?? kAudioDeviceTransportTypeUnknown
        return AudioInputDevice(id: id, uid: uid, name: name, transport: transport(forTransportType: raw))
    }

    private static func hasInputStreams(_ id: AudioObjectID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return status == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func readUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, size == UInt32(MemoryLayout<UInt32>.size) else { return nil }
        return value
    }

    private static func readObjectIDs(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> [AudioObjectID]? {
        let stride = MemoryLayout<AudioObjectID>.stride
        var address = propertyAddress(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / stride)
        guard !ids.isEmpty else { return [] }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / stride))
    }

    /// The HAL returns string properties at +1.
    private static func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard let string = value?.takeRetainedValue(), status == noErr else { return nil }
        return string as String
    }
}
