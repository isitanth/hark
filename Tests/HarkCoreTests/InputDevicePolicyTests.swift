import Foundation
import HarkCore
import Testing

struct DeviceCase: Sendable, CustomTestStringConvertible {
    let name: String
    var policy = InputDevicePolicy()
    let devices: [AudioInputDevice]
    var systemDefault: UInt32?
    let mode: CaptureMode
    let pick: AudioInputDevice?
    var warning: InputDeviceWarning?

    var testDescription: String { name }
}

private enum Mic {
    static let builtIn = AudioInputDevice(
        id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
    static let airPods = AudioInputDevice(
        id: 20, uid: "AC-DE-48-00-11-22:input", name: "AirPods", transport: .bluetooth)
    static let airPodsLE = AudioInputDevice(id: 21, uid: "LE-AirPods", name: "AirPods Pro", transport: .bluetoothLE)
    static let usb = AudioInputDevice(id: 30, uid: "AppleUSBAudioEngine:Shure:MV7", name: "MV7", transport: .usb)
    static let iPhone = AudioInputDevice(id: 40, uid: "continuity-iphone", name: "iPhone", transport: .continuity)
}

private let all = [Mic.usb, Mic.builtIn, Mic.airPods, Mic.airPodsLE, Mic.iPhone]
private let external = [Mic.usb, Mic.airPods]
private let wireless = [Mic.airPodsLE, Mic.airPods]
private let prefersUSB = InputDevicePolicy(preferredUID: Mic.usb.uid)
private let prefersAirPods = InputDevicePolicy(preferredUID: Mic.airPods.uid)
private let prefersAirPodsLE = InputDevicePolicy(preferredUID: Mic.airPodsLE.uid)
private let prefersUnplugged = InputDevicePolicy(preferredUID: "unplugged")
private let followsSystem = InputDevicePolicy(preferBuiltInWhenAlwaysOn: false)

let deviceCases: [DeviceCase] = [
    .init(name: "push-to-talk, no devices", devices: [], systemDefault: 20, mode: .pushToTalk, pick: nil),
    .init(name: "always-on, no devices", devices: [], systemDefault: 20, mode: .alwaysOn, pick: nil),
    .init(
        name: "push-to-talk, missing preference and no devices", policy: prefersUnplugged, devices: [],
        mode: .pushToTalk, pick: nil),

    .init(
        name: "push-to-talk follows the system default, AirPods included", devices: all, systemDefault: 20,
        mode: .pushToTalk, pick: Mic.airPods),
    .init(
        name: "push-to-talk prefers the chosen device over the default", policy: prefersUSB, devices: all,
        systemDefault: 20, mode: .pushToTalk, pick: Mic.usb),
    .init(
        name: "push-to-talk on chosen AirPods has no Bluetooth warning", policy: prefersAirPods, devices: all,
        systemDefault: 10, mode: .pushToTalk, pick: Mic.airPods),
    .init(
        name: "push-to-talk, chosen device unplugged: system default and a warning", policy: prefersUnplugged,
        devices: all, systemDefault: 30, mode: .pushToTalk, pick: Mic.usb, warning: .preferredDeviceMissing),
    .init(
        name: "push-to-talk, no system default: first built-in", devices: all, systemDefault: nil,
        mode: .pushToTalk, pick: Mic.builtIn),
    .init(
        name: "push-to-talk, stale system default: first built-in", devices: all, systemDefault: 99,
        mode: .pushToTalk, pick: Mic.builtIn),
    .init(
        name: "push-to-talk, no default and no built-in: first device", devices: external, systemDefault: nil,
        mode: .pushToTalk, pick: Mic.usb),
    .init(
        name: "push-to-talk, chosen device unplugged, nothing else to go on", policy: prefersUnplugged,
        devices: external, systemDefault: nil, mode: .pushToTalk, pick: Mic.usb, warning: .preferredDeviceMissing),

    .init(
        name: "always-on ignores AirPods as the system default", devices: all, systemDefault: 20, mode: .alwaysOn,
        pick: Mic.builtIn),
    .init(
        name: "always-on ignores the system default even when wired", devices: all, systemDefault: 30,
        mode: .alwaysOn, pick: Mic.builtIn),
    .init(
        name: "always-on honours a chosen USB mic", policy: prefersUSB, devices: all, systemDefault: 20,
        mode: .alwaysOn, pick: Mic.usb),
    .init(
        name: "always-on forced onto AirPods warns", policy: prefersAirPods, devices: all, systemDefault: 10,
        mode: .alwaysOn, pick: Mic.airPods, warning: .bluetoothWhileAlwaysOn),
    .init(
        name: "always-on forced onto Bluetooth LE warns", policy: prefersAirPodsLE, devices: all, systemDefault: 10,
        mode: .alwaysOn, pick: Mic.airPodsLE, warning: .bluetoothWhileAlwaysOn),
    .init(
        name: "always-on, chosen device unplugged: built-in and a warning", policy: prefersUnplugged, devices: all,
        systemDefault: 20, mode: .alwaysOn, pick: Mic.builtIn, warning: .preferredDeviceMissing),
    .init(
        name: "always-on, chosen device unplugged onto AirPods: missing wins", policy: prefersUnplugged,
        devices: wireless, systemDefault: 20, mode: .alwaysOn, pick: Mic.airPods, warning: .preferredDeviceMissing),
    .init(
        name: "always-on without the built-in preference follows the default", policy: followsSystem, devices: all,
        systemDefault: 30, mode: .alwaysOn, pick: Mic.usb),
    .init(
        name: "always-on without the built-in preference lands on AirPods and warns", policy: followsSystem,
        devices: all, systemDefault: 20, mode: .alwaysOn, pick: Mic.airPods, warning: .bluetoothWhileAlwaysOn),
    .init(
        name: "always-on without the built-in preference, no default: first built-in", policy: followsSystem,
        devices: all, systemDefault: nil, mode: .alwaysOn, pick: Mic.builtIn),
    .init(
        name: "always-on, no built-in: system default, and it is AirPods", devices: external, systemDefault: 20,
        mode: .alwaysOn, pick: Mic.airPods, warning: .bluetoothWhileAlwaysOn),
    .init(
        name: "always-on, no built-in and no default: first device, and it is Bluetooth", devices: wireless,
        systemDefault: nil, mode: .alwaysOn, pick: Mic.airPodsLE, warning: .bluetoothWhileAlwaysOn),
    .init(
        name: "always-on, no built-in and no default: first device, wired", devices: external,
        systemDefault: nil, mode: .alwaysOn, pick: Mic.usb),
]

@Suite struct InputDevicePolicyTests {
    @Test func defaults() {
        let policy = InputDevicePolicy()
        #expect(policy.preferredUID == nil)
        #expect(policy.preferBuiltInWhenAlwaysOn)
    }

    @Test(arguments: deviceCases)
    func choose(_ scenario: DeviceCase) {
        let choice = scenario.policy.choose(
            from: scenario.devices, systemDefault: scenario.systemDefault, mode: scenario.mode)
        #expect(choice == scenario.pick.map { InputDeviceChoice(device: $0, warning: scenario.warning) })
    }
}
