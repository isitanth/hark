import Foundation
import Testing
import os

@testable import HarkCore

/// A defaults suite of its own, kept in the temporary directory by its absolute name and removed at the end.
private final class ScratchDefaults {
    let directory: TemporaryDirectory
    let name: String
    let defaults: UserDefaults

    init() throws {
        directory = try TemporaryDirectory()
        name = directory.url.appendingPathComponent("preferences").path
        defaults = try #require(UserDefaults(suiteName: name))
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

/// Output devices by UID, each with a volume, whether it can be set, and an optional step it rounds every set to.
private final class FakeOutputVolume: SystemOutputVolume {
    struct Device: Sendable {
        var volume: Float?
        var settable = true
        var step: Float?
    }

    struct SetCall: Sendable, Equatable {
        let uid: String
        let volume: Float
    }

    struct State: Sendable {
        var devices: [String: Device] = [:]
        var defaultUID: String?
        var sets: [SetCall] = []
        /// Whether the ducking record was in the defaults at each set.
        var recordAtSet: [Bool] = []
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    private let recordPresent: @Sendable () -> Bool

    init(recordPresent: @escaping @Sendable () -> Bool = { false }) {
        self.recordPresent = recordPresent
    }

    func add(_ uid: String, volume: Float?, settable: Bool = true, step: Float? = nil, isDefault: Bool = true) {
        state.withLock {
            $0.devices[uid] = Device(volume: volume, settable: settable, step: step)
            if isDefault { $0.defaultUID = uid }
        }
    }

    /// The user, or another app, moves the volume.
    func userSets(_ volume: Float, of uid: String) {
        state.withLock { $0.devices[uid]?.volume = volume }
    }

    func remove(_ uid: String) {
        state.withLock {
            $0.devices[uid] = nil
            if $0.defaultUID == uid { $0.defaultUID = nil }
        }
    }

    func reading(_ uid: String) -> Float? { state.withLock { $0.devices[uid]?.volume } }
    var sets: [SetCall] { state.withLock { $0.sets } }
    var recordAtSet: [Bool] { state.withLock { $0.recordAtSet } }

    func defaultOutputUID() -> String? { state.withLock { $0.defaultUID } }

    func volume(of uid: String) -> Float? { reading(uid) }

    func isSettable(_ uid: String) -> Bool { state.withLock { $0.devices[uid]?.settable ?? false } }

    func setVolume(_ volume: Float, of uid: String) -> Float? {
        let present = recordPresent()
        return state.withLock { state -> Float? in
            state.recordAtSet.append(present)
            state.sets.append(SetCall(uid: uid, volume: volume))
            guard var device = state.devices[uid], device.settable, device.volume != nil else { return nil }
            let stored = device.step.map { ($0 * (volume / $0).rounded()) } ?? volume
            device.volume = stored
            state.devices[uid] = device
            return stored
        }
    }
}

private final class DuckingFixture {
    let scratch: ScratchDefaults
    let fake: FakeOutputVolume
    let ducker: OutputDucker

    init() throws {
        scratch = try ScratchDefaults()
        let name = scratch.name
        fake = FakeOutputVolume(recordPresent: {
            UserDefaults(suiteName: name)?.data(forKey: OutputDucker.recordKey) != nil
        })
        nonisolated(unsafe) let defaults = scratch.defaults
        ducker = OutputDucker(volume: fake, defaults: defaults)
    }

    /// The same defaults and devices, as the next launch would find them.
    func relaunched() -> OutputDucker {
        nonisolated(unsafe) let defaults = scratch.defaults
        return OutputDucker(volume: fake, defaults: defaults)
    }

    func writeRecord(_ record: LoweredOutput) throws {
        scratch.defaults.set(try JSONEncoder().encode(record), forKey: OutputDucker.recordKey)
    }
}

@Suite("OutputDucking")
struct OutputDuckingTests {
    @Test(arguments: [
        (Float(0.24), true), (0.2495, true), (0.2305, true), (0.2505, false), (0.2295, false), (0.8, false),
    ])
    func restoresWithinTheToleranceOfTheTarget(reading: Float, expected: Bool) {
        let record = LoweredOutput(uid: "A", original: 0.8, target: 0.24)
        #expect(OutputDucking.shouldRestore(record, reading: reading) == expected)
    }

    @Test func restoresThroughTheReadBack() {
        let record = LoweredOutput(uid: "A", original: 0.8, target: 0.24, readBack: 0.1875)
        #expect(OutputDucking.shouldRestore(record, reading: 0.1875))
        #expect(!OutputDucking.shouldRestore(record, reading: 0.5))
        #expect(!OutputDucking.shouldRestore(record, reading: nil))
    }

    @Test func lowersToThreeTenthsAndRecordsIt() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        await fixture.ducker.begin(enabled: true)
        let reading = try #require(fixture.fake.reading("A"))
        #expect(abs(reading - 0.24) < 1e-6)
        let record = try #require(await fixture.ducker.record)
        #expect(record.uid == "A")
        #expect(record.original == 0.8)
        #expect(abs(record.target - 0.24) < 1e-6)
        #expect(record.readBack == reading)
    }

    @Test func notSettableNeitherSetsNorRecords() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("HDMI", volume: 0.8, settable: false)
        await fixture.ducker.begin(enabled: true)
        #expect(fixture.fake.sets.isEmpty)
        #expect(await fixture.ducker.record == nil)
    }

    @Test func noDefaultOutputDoesNothing() async throws {
        let fixture = try DuckingFixture()
        await fixture.ducker.begin(enabled: true)
        #expect(fixture.fake.sets.isEmpty)
        #expect(await fixture.ducker.record == nil)
    }

    @Test func restoresWhenTheDeviceReadsWhatWasSet() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        await fixture.ducker.begin(enabled: true)
        await fixture.ducker.end()
        #expect(fixture.fake.reading("A") == 0.8)
        #expect(await fixture.ducker.record == nil)
    }

    @Test func leftAloneWhenTheUserChangedIt() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        await fixture.ducker.begin(enabled: true)
        fixture.fake.userSets(0.5, of: "A")
        await fixture.ducker.end()
        #expect(fixture.fake.reading("A") == 0.5)
        #expect(fixture.fake.sets.count == 1)
        #expect(await fixture.ducker.record == nil)
    }

    @Test func restoresTheLoweredDeviceNotTheNewDefault() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("Speakers", volume: 0.8)
        await fixture.ducker.begin(enabled: true)
        fixture.fake.add("AirPods", volume: 0.6)
        await fixture.ducker.end()
        #expect(fixture.fake.reading("Speakers") == 0.8)
        #expect(fixture.fake.reading("AirPods") == 0.6)
        #expect(fixture.fake.sets.map(\.uid) == ["Speakers", "Speakers"])
    }

    @Test func aDeviceGoneClearsTheRecord() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("AirPods", volume: 0.8)
        await fixture.ducker.begin(enabled: true)
        fixture.fake.remove("AirPods")
        await fixture.ducker.end()
        #expect(fixture.fake.sets.count == 1)
        #expect(await fixture.ducker.record == nil)
    }

    @Test func aRoundingDeviceRestoresThroughTheReadBack() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("USB", volume: 0.8, step: 0.2)
        await fixture.ducker.begin(enabled: true)
        let record = try #require(await fixture.ducker.record)
        #expect(record.readBack == 0.2)
        await fixture.ducker.end()
        #expect(fixture.fake.reading("USB") == 0.8)
        #expect(await fixture.ducker.record == nil)
    }

    @Test func theRecordIsWrittenBeforeTheSet() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        await fixture.ducker.begin(enabled: true)
        #expect(fixture.fake.recordAtSet == [true])
    }

    @Test func aLeftoverRecordIsRestoredAtLaunchAndCleared() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        await fixture.ducker.begin(enabled: true)
        let next = fixture.relaunched()
        await next.recoverAtLaunch()
        #expect(fixture.fake.reading("A") == 0.8)
        #expect(await next.record == nil)
    }

    @Test func aCrashBeforeTheSetClearsAtLaunchAndChangesNothing() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        try fixture.writeRecord(LoweredOutput(uid: "A", original: 0.8, target: 0.24))
        let next = fixture.relaunched()
        await next.recoverAtLaunch()
        #expect(fixture.fake.reading("A") == 0.8)
        #expect(fixture.fake.sets.isEmpty)
        #expect(await next.record == nil)
    }

    @Test func aSecondBeginKeepsTheOriginal() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        await fixture.ducker.begin(enabled: true)
        await fixture.ducker.begin(enabled: true)
        #expect(await fixture.ducker.record?.original == 0.8)
        #expect(fixture.fake.sets.count == 1)
        await fixture.ducker.end()
        #expect(fixture.fake.reading("A") == 0.8)
    }

    @Test func anEndWithoutABeginDoesNothing() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        await fixture.ducker.end()
        #expect(fixture.fake.sets.isEmpty)
        #expect(fixture.fake.reading("A") == 0.8)
    }

    /// A headset's microphone switches it between two modes with a volume each, so the restore would read the other.
    @Test(arguments: [AudioTransport.bluetooth, .bluetoothLE])
    func aBluetoothMicrophoneSkipsTheLowering(_ input: AudioTransport) async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        await fixture.ducker.begin(enabled: true, input: input)
        await fixture.ducker.end()
        #expect(fixture.fake.sets.isEmpty)
        #expect(await fixture.ducker.record == nil)
    }

    /// The Mac's microphone chosen in Hark while a headset is the default input: the engine still wakes the headset.
    @Test func aBluetoothDefaultInputSkipsTheLoweringToo() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        await fixture.ducker.begin(enabled: true, input: .builtIn, systemDefault: .bluetooth)
        await fixture.ducker.end()
        #expect(fixture.fake.sets.isEmpty)
        #expect(await fixture.ducker.record == nil)
    }

    @Test(arguments: [AudioTransport.builtIn, .usb, .continuity])
    func anotherMicrophoneStillLowers(_ input: AudioTransport) async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        await fixture.ducker.begin(enabled: true, input: input)
        #expect(await fixture.ducker.record?.target == 0.8 * OutputDucking.factor)
    }

    @Test func disabledAtBeginDoesNothing() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        await fixture.ducker.begin(enabled: false)
        await fixture.ducker.end()
        #expect(fixture.fake.sets.isEmpty)
        #expect(await fixture.ducker.record == nil)
    }

    /// Turning the setting off mid-capture does not reach end(): what was lowered comes back.
    @Test func beginEnabledThenEndStillRestores() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0.8)
        await fixture.ducker.begin(enabled: true)
        await fixture.ducker.end()
        #expect(fixture.fake.reading("A") == 0.8)
    }

    /// Mute is a separate property: a muted output reports its volume and is lowered and restored like any other.
    @Test func aSilentOutputIsLoweredAndRestored() async throws {
        let fixture = try DuckingFixture()
        fixture.fake.add("A", volume: 0)
        await fixture.ducker.begin(enabled: true)
        await fixture.ducker.end()
        #expect(fixture.fake.sets.map(\.volume) == [0, 0])
        #expect(await fixture.ducker.record == nil)
    }
}
