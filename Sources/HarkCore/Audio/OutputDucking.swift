import Foundation
import os

/// The output device's main volume, as Hark needs it to lower other audio while recording. Synchronous: each call is
/// a HAL property read or write, made from the `OutputDucker` actor.
public protocol SystemOutputVolume: Sendable {
    /// The UID of the default output device; nil when there is none.
    func defaultOutputUID() -> String?
    /// The device's main volume from 0 to 1; nil when the device is gone or has no main volume.
    func volume(of uid: String) -> Float?
    /// Whether the device's main volume can be set; false when the device is gone.
    func isSettable(_ uid: String) -> Bool
    /// Sets the device's main volume and returns what it reads back, which a stepped device may round; nil on failure.
    func setVolume(_ volume: Float, of uid: String) -> Float?
}

/// What Hark lowered, persisted before the set so a crash between the set and the restore can be undone at launch.
public struct LoweredOutput: Codable, Sendable, Equatable {
    public let uid: String
    public let original: Float
    public let target: Float
    /// What the device read after the set; nil until the set has returned, or when it failed.
    public var readBack: Float?

    public init(uid: String, original: Float, target: Float, readBack: Float? = nil) {
        self.uid = uid
        self.original = original
        self.target = target
        self.readBack = readBack
    }
}

public enum OutputDucking {
    /// The lowered volume is this fraction of the one found.
    public static let factor: Float = 0.3
    /// How far a reading may be from what Hark set and still count as untouched.
    public static let tolerance: Float = 0.01

    /// Restore only when the device still reads what Hark set (the target, or the read-back of a device that rounds
    /// to its steps): any other value means the user moved the volume since, and it is theirs.
    public static func shouldRestore(_ record: LoweredOutput, reading: Float?) -> Bool {
        guard let reading else { return false }
        if abs(reading - record.target) <= tolerance { return true }
        if let readBack = record.readBack, abs(reading - readBack) <= tolerance { return true }
        return false
    }
}

/// Lowers the default output for the length of a capture and puts it back only when nobody touched it since. The
/// record lives in UserDefaults, not in memory, so a crash or an `_exit` past the quit deadline is undone at launch.
///
/// An actor, not the main actor: the plan kept these calls on the main thread unless one measured over 5 ms, and in
/// the installed app (2026-09-27/28) a lowering or a restore took 7.9 to 12.1 ms on the built-in speakers and 7.95 to
/// 16.8 ms on AirPods, long enough to hold up the key press and the HUD it opens.
public actor OutputDucker {
    public static let recordKey = "HarkLoweredOutput"

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "audio")

    private let volume: any SystemOutputVolume
    private let defaults: UserDefaults

    public init(volume: any SystemOutputVolume, defaults: UserDefaults) {
        self.volume = volume
        self.defaults = defaults
    }

    /// The record of a lowering not yet put back; nil when there is none or it cannot be decoded.
    public var record: LoweredOutput? {
        guard let data = defaults.data(forKey: Self.recordKey) else { return nil }
        return try? JSONDecoder().decode(LoweredOutput.self, from: data)
    }

    /// Lowers the default output to `factor` of its volume. A record already there means a lowering is in effect,
    /// and its original must not be replaced by the lowered value.
    ///
    /// Not when the capture's input is a Bluetooth microphone (`input`). A headset switches to its headset mode when
    /// its microphone opens and back when it closes, and each mode has its own volume: measured 2026-09-28 with
    /// AirPods, Hark lowered 0.1875 to 0.05625 in music mode, read 0.1875 in headset mode at key up, took it for the
    /// user's change and left the music at 30 %, lower at every dictation. The plan named this fallback (risk 9).
    ///
    /// Nor when the system's default input is one (`systemDefault`), whatever Hark records from: AVAudioEngine opens
    /// the default input first at every press, so the headset switches mode anyway. Measured 2026-09-28 with the
    /// MacBook microphone chosen in Hark and AirPods as the default input: five dictations took the AirPods from 0.06
    /// to 0.00049.
    public func begin(enabled: Bool, input: AudioTransport? = nil, systemDefault: AudioTransport? = nil) {
        guard enabled, defaults.data(forKey: Self.recordKey) == nil else { return }
        if Self.isHeadset(input) || Self.isHeadset(systemDefault) {
            Self.logger.info("lower output: a Bluetooth headset's microphone is involved, skipped")
            return
        }
        let start = ContinuousClock.now
        guard let uid = volume.defaultOutputUID() else {
            Self.logger.info("lower output: no default output device, skipped")
            return
        }
        guard volume.isSettable(uid), let original = volume.volume(of: uid) else {
            Self.logger.info("lower output: \(uid, privacy: .public) has no settable volume, skipped")
            return
        }
        var lowered = LoweredOutput(uid: uid, original: original, target: original * OutputDucking.factor)
        write(lowered)
        lowered.readBack = volume.setVolume(lowered.target, of: uid)
        write(lowered)
        let readBack = lowered.readBack.map { "\($0)" } ?? "nil"
        Self.logger.info(
            """
            lower output: \(uid, privacy: .public) \(original) -> \(lowered.target), read back \
            \(readBack, privacy: .public), \(Self.elapsed(since: start), privacy: .public)
            """)
    }

    private static func isHeadset(_ transport: AudioTransport?) -> Bool {
        transport == .bluetooth || transport == .bluetoothLE
    }

    /// Puts the lowered device back, on the device recorded rather than the current default.
    public func end() {
        restore(reason: "end")
    }

    /// Undoes a lowering a crash or a forced exit left behind. When the set never happened, the device still reads
    /// its original and clearing the record is all there is to do.
    public func recoverAtLaunch() {
        restore(reason: "launch")
    }

    private func restore(reason: String) {
        guard defaults.data(forKey: Self.recordKey) != nil else { return }
        let start = ContinuousClock.now
        defer { defaults.removeObject(forKey: Self.recordKey) }
        guard let lowered = record else {
            Self.logger.error("restore output (\(reason, privacy: .public)): unreadable record, cleared")
            return
        }
        let uid = lowered.uid
        guard let reading = volume.volume(of: uid) else {
            Self.logger.info("restore output (\(reason, privacy: .public)): \(uid, privacy: .public) gone, cleared")
            return
        }
        guard OutputDucking.shouldRestore(lowered, reading: reading) else {
            Self.logger.info(
                """
                restore output (\(reason, privacy: .public)): \(uid, privacy: .public) reads \(reading), not what \
                was set, left alone
                """)
            return
        }
        let readBack = volume.setVolume(lowered.original, of: uid).map { "\($0)" } ?? "nil"
        Self.logger.info(
            """
            restore output (\(reason, privacy: .public)): \(uid, privacy: .public) \(reading) -> \(lowered.original), \
            read back \(readBack, privacy: .public), \(Self.elapsed(since: start), privacy: .public)
            """)
    }

    private func write(_ lowered: LoweredOutput) {
        do {
            defaults.set(try JSONEncoder().encode(lowered), forKey: Self.recordKey)
        } catch {
            Self.logger.error(
                "cannot encode the lowered output record: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> String {
        let duration = ContinuousClock.now - start
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.2f ms", ms)
    }
}
