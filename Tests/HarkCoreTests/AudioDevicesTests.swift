import CoreAudio
import Foundation
import HarkCore
import Testing

@Suite struct AudioDevicesTests {
    @Test(arguments: [
        (kAudioDeviceTransportTypeBuiltIn, AudioTransport.builtIn),
        (kAudioDeviceTransportTypeUSB, .usb),
        (kAudioDeviceTransportTypeBluetooth, .bluetooth),
        (kAudioDeviceTransportTypeBluetoothLE, .bluetoothLE),
        (kAudioDeviceTransportTypeContinuityCaptureWired, .continuity),
        (kAudioDeviceTransportTypeContinuityCaptureWireless, .continuity),
        (kAudioDeviceTransportTypeAggregate, .aggregate),
        (kAudioDeviceTransportTypeAutoAggregate, .aggregate),
        (kAudioDeviceTransportTypeVirtual, .virtual),
        (kAudioDeviceTransportTypeAirPlay, .airPlay),
        (kAudioDeviceTransportTypeUnknown, .other),
        (kAudioDeviceTransportTypePCI, .other),
        (kAudioDeviceTransportTypeFireWire, .other),
        (kAudioDeviceTransportTypeHDMI, .other),
        (kAudioDeviceTransportTypeDisplayPort, .other),
        (kAudioDeviceTransportTypeAVB, .other),
        (kAudioDeviceTransportTypeThunderbolt, .other),
        (0xFFFF_FFFF, .other),
    ])
    func transport(_ raw: UInt32, _ expected: AudioTransport) {
        #expect(AudioDevices.transport(forTransportType: raw) == expected)
    }

    @Test func changesFinishesWhenIterationIsCancelled() async {
        let task = Task {
            var count = 0
            for await _ in AudioDevices.changes() { count += 1 }
            return count
        }
        task.cancel()
        _ = await task.value
    }

    /// Switches the system default input to another input device and back, so it only runs when asked:
    /// HARK_TEST_SWITCH_DEFAULT_INPUT=1 on a machine with two input devices. The microphone is never opened.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARK_TEST_SWITCH_DEFAULT_INPUT"] == "1"))
    func changesYieldsWhenTheDefaultInputSwitches() async throws {
        let original = try #require(AudioDevices.defaultInputDeviceID())
        let other = try #require(AudioDevices.inputDevices().first { $0.id != original }?.id)
        let stream = AudioDevices.changes()
        let received = Task {
            for await _ in stream { return true }
            return false
        }
        #expect(Self.setDefaultInput(other) == noErr)
        let changed = await received.value
        #expect(Self.setDefaultInput(original) == noErr)
        #expect(changed)
        #expect(AudioDevices.defaultInputDeviceID() == original)
    }

    private static func setDefaultInput(_ id: UInt32) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = AudioObjectID(id)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size),
            &value)
    }
}
