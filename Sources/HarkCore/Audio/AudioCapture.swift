import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import HarkObjC
import os

/// Push-to-talk capture: one AVCaptureSession per utterance, delivering 16 kHz mono Float32 kept in memory.
///
/// AVCaptureSession opens only the device it is given. AVAudioEngine, used until M7.25, opened the system's default
/// input when its input node was created, whatever device it was then bound to: measured 2026-09-28 with AirPods as
/// the default input and the MacBook microphone chosen in Hark, every press woke the AirPods into their headset mode
/// (the music degraded) and the switch to the Mac microphone took 2-5 s, so short dictations came back silent. The
/// user chose AVCaptureSession that day. Nothing is opened while idle, and the device is chosen at each press. The
/// session's calls block (start 76-88 ms, stop 17-24 ms, measured), so they run on a private serial queue that the
/// actor awaits; the sample delegate writes into `CaptureSink` on its own queue and never touches actor state.
public actor AudioCapture: AudioInput {
    public nonisolated let events: AsyncStream<AudioInputEvent>

    /// The utterance's session; nil while idle.
    private var session: CaptureSession?
    private let sink: CaptureSink
    private var policy: InputDevicePolicy
    private let dumpURL: URL?
    /// The device the utterance's session was opened on.
    private var activeDevice: AudioInputDevice?
    /// A preference set mid-utterance, applied once the utterance ends.
    private var deferredPreferredUID: String??
    private var current: UtteranceID?
    /// Highest utterance already stopped or cancelled. IDs only grow, so a `start` at or below it was overtaken by
    /// its own `stop` or `cancel` and must not open the microphone.
    private var closedThrough: UInt64 = 0
    /// Set when a lost device ends an utterance, so its `stop` reports the same failure.
    private var interruption: (id: UtteranceID, failure: PipelineFailure)?
    private var deviceListObserver: TaskCancellation?
    /// Every session call, across utterances, runs here in order: a press's start never overtakes the previous
    /// utterance's stop.
    private let sessionQueue = DispatchQueue(label: "hark.capture.session")
    private let sampleQueue = DispatchQueue(label: "hark.capture.samples")

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "audio")

    /// `dumpURL` is honoured only in builds compiled with `HARK_DEBUG_AUDIO`.
    public init(
        policy: InputDevicePolicy = InputDevicePolicy(), maxDuration: Duration = SampleBuffer.defaultMaxDuration,
        dumpURL: URL? = nil
    ) {
        let (events, continuation) = AsyncStream.makeStream(of: AudioInputEvent.self)
        self.events = events
        self.sink = CaptureSink(maxDuration: maxDuration, continuation: continuation)
        self.policy = policy
        self.dumpURL = dumpURL
    }

    /// Starts watching the system's inputs, so a device that goes away mid-dictation ends it. Opens no device. Call at
    /// launch.
    public func prepare() {
        guard deviceListObserver == nil else { return }
        deviceListObserver = TaskCancellation(
            Task { [weak self] in
                for await _ in AudioDevices.changes() { await self?.inputDevicesChanged() }
            })
    }

    /// Captures from the input with this UID, or from the system default when nil, from the next press; an utterance
    /// in flight keeps its device. A UID that is not attached falls back to the default.
    public func setPreferredDevice(uid: String?) {
        guard current == nil else {
            deferredPreferredUID = .some(uid)
            return
        }
        deferredPreferredUID = nil
        policy.preferredUID = uid
    }

    private func applyDeferredPreference() {
        guard let uid = deferredPreferredUID else { return }
        deferredPreferredUID = nil
        policy.preferredUID = uid
    }

    public func start(_ id: UtteranceID) async throws(PipelineFailure) {
        guard id.rawValue > closedThrough else { return }
        switch MicPermission.status {
        case .granted:
            break
        case .denied:
            throw .micPermissionDenied
        case .undetermined:
            Task { _ = await MicPermission.request() }
            throw .micPermissionDenied
        }
        applyDeferredPreference()
        let device = try chooseDevice()
        guard let captureDevice = AVCaptureDevice(uniqueID: device.uid) else {
            Self.logger.error(
                "no capture device for \(device.name, privacy: .public) [\(device.uid, privacy: .public)]")
            throw .noInputDevice
        }
        let capture = CaptureSession(
            device: captureDevice, id: id, sink: sink, queue: sessionQueue, sampleQueue: sampleQueue,
            onLoss: { [weak self] in Task { await self?.deviceLost(id) } })
        session = capture
        activeDevice = device
        current = id
        sink.arm(id)
        Self.logger.info(
            "capture on \(device.name, privacy: .public) [\(device.transport.rawValue, privacy: .public)]")
        let failure = await capture.start()
        // The start is awaited, so a stop, a cancel or a lost device may have ended the utterance meanwhile; each of
        // them released the session.
        guard current == id, session === capture else { return }
        if let failure {
            current = nil
            _ = sink.disarm()
            await release()
            applyDeferredPreference()
            throw failure
        }
    }

    public func stop(_ id: UtteranceID) async throws(PipelineFailure) -> CapturedAudio {
        closedThrough = max(closedThrough, id.rawValue)
        if let interruption, interruption.id == id {
            self.interruption = nil
            throw interruption.failure
        }
        guard current == id else {
            return CapturedAudio(summary: CaptureSummary(durationMs: 0, peakRMS: 0, meanRMS: 0), samples: [])
        }
        current = nil
        let audio = sink.disarm()
        await release()
        #if HARK_DEBUG_AUDIO
            if let dumpURL { AudioDump.save(audio.samples, to: dumpURL) }
        #endif
        applyDeferredPreference()
        return audio
    }

    public func cancel(_ id: UtteranceID) async {
        closedThrough = max(closedThrough, id.rawValue)
        if interruption?.id == id { interruption = nil }
        guard current == id else { return }
        current = nil
        _ = sink.disarm()
        await release()
        applyDeferredPreference()
    }

    /// Stops the utterance's session and lets it go, and with it the device: a Bluetooth headset goes back to its
    /// music mode. The session is detached before the await, so a press that lands meanwhile finds none.
    private func release() async {
        guard let session else { return }
        self.session = nil
        activeDevice = nil
        await session.stop()
    }

    private func chooseDevice() throws(PipelineFailure) -> AudioInputDevice {
        let choice = policy.choose(
            from: AudioDevices.inputDevices(), systemDefault: AudioDevices.defaultInputDeviceID(), mode: .pushToTalk)
        guard let choice else { throw .noInputDevice }
        return choice.device
    }

    /// The system's inputs or its default input changed. A recording whose device is no longer the policy's choice
    /// ends: the device went away, or the default it followed moved. While idle nothing is open.
    private func inputDevicesChanged() async {
        guard let id = current, let activeDevice else { return }
        let choice = try? chooseDevice()
        guard choice?.uid != activeDevice.uid else { return }
        await deviceLost(id)
    }

    /// The session reported a runtime error or an interruption, its device was disconnected, or it delivered a format
    /// other than the one asked for. The utterance ends as a device change. A new format on the same device (AirPods
    /// switching profile) never gets here: the output converts it.
    private func deviceLost(_ id: UtteranceID) async {
        guard current == id else { return }
        Self.logger.error("capture device lost mid-utterance")
        current = nil
        _ = sink.disarm()
        interruption = (id, .deviceChanged)
        sink.report(.interrupted(id, .deviceChanged))
        await release()
        applyDeferredPreference()
    }
}

/// One utterance's AVCaptureSession. Every call on the session runs on `queue`, one at a time: AVFoundation raises an
/// Objective-C exception, which Swift cannot catch, when `startRunning` lands between `beginConfiguration` and
/// `commitConfiguration`, and the configuration is committed before the start on that same queue.
///
/// `@unchecked Sendable` because the session, its output and the observer tokens are touched only on `queue`.
final class CaptureSession: @unchecked Sendable {
    /// One constant dictionary: a bad key, or a float bit depth other than 32, raises an exception.
    nonisolated(unsafe) static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: SampleBuffer.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let delegate: SampleDelegate
    private let queue: DispatchQueue
    private let sampleQueue: DispatchQueue
    private let onLoss: @Sendable () -> Void
    private var observers: [any NSObjectProtocol] = []

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "audio")

    init(
        device: AVCaptureDevice, id: UtteranceID, sink: CaptureSink, queue: DispatchQueue, sampleQueue: DispatchQueue,
        onLoss: @escaping @Sendable () -> Void
    ) {
        self.device = device
        self.queue = queue
        self.sampleQueue = sampleQueue
        self.onLoss = onLoss
        delegate = SampleDelegate(id: id, sink: sink, onLoss: onLoss)
    }

    /// Configures and starts the session on its queue; nil once it runs.
    func start() async -> PipelineFailure? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.startOnQueue()) }
        }
    }

    /// Stops the session on its queue and drops its observers.
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.session.stopRunning()
                for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
                self.observers = []
                continuation.resume()
            }
        }
    }

    private func startOnQueue() -> PipelineFailure? {
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            Self.logger.error(
                "capture input on \(self.device.localizedName, privacy: .public): \(error, privacy: .public)")
            return .audioEngine(code: Int32(truncatingIfNeeded: (error as NSError).code))
        }
        var added = false
        session.beginConfiguration()
        let configuring = HarkCatchException {
            output.audioSettings = Self.audioSettings
            output.setSampleBufferDelegate(delegate, queue: sampleQueue)
            guard session.canAddInput(input), session.canAddOutput(output) else { return }
            session.addInput(input)
            session.addOutput(output)
            added = true
        }
        session.commitConfiguration()
        if let configuring { return failure(configuring, in: "session configuration") }
        guard added else {
            Self.logger.error("the capture session refused \(self.device.localizedName, privacy: .public)")
            return .noInputDevice
        }
        observe()
        if let starting = HarkCatchException({ session.startRunning() }) {
            return failure(starting, in: "session start")
        }
        guard session.isRunning else {
            Self.logger.error("the capture session on \(self.device.localizedName, privacy: .public) did not start")
            return .audioEngine(code: 0)
        }
        return nil
    }

    private func failure(_ exception: any Error, in what: StaticString) -> PipelineFailure {
        let name = (exception as NSError).userInfo["name"] as? String ?? "unknown"
        Self.logger.error(
            "\(what, privacy: .public) raised \(name, privacy: .public): \(exception.localizedDescription, privacy: .public)"
        )
        return .deviceChanged
    }

    /// Before the start, so a runtime error while starting is seen too.
    private func observe() {
        let onLoss = onLoss
        let center = NotificationCenter.default
        let names: [(Notification.Name, AnyObject)] = [
            (AVCaptureSession.runtimeErrorNotification, session),
            (AVCaptureSession.wasInterruptedNotification, session),
            (AVCaptureDevice.wasDisconnectedNotification, device),
        ]
        observers = names.map { name, object in
            center.addObserver(forName: name, object: object, queue: nil) { notification in
                Self.logger.error("\(notification.name.rawValue, privacy: .public)")
                onLoss()
            }
        }
    }
}

/// Receives the session's sample buffers on the sample queue and hands their samples to the sink.
///
/// `@unchecked Sendable` because `checked` and `rejected` are touched only on the sample queue.
final class SampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let id: UtteranceID
    private let sink: CaptureSink
    private let onLoss: @Sendable () -> Void
    private var checked = false
    private var rejected = false

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "audio")

    init(id: UtteranceID, sink: CaptureSink, onLoss: @escaping @Sendable () -> Void) {
        self.id = id
        self.sink = sink
        self.onLoss = onLoss
    }

    /// Whether a delivered format is the one asked for. Read from the buffers, because the output's `audioSettings`
    /// reads back only its format ID.
    static func isExpected(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate == SampleBuffer.sampleRate
            && format.mChannelsPerFrame == 1 && format.mBitsPerChannel == 32
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        if !checked {
            checked = true
            let format = CMSampleBufferGetFormatDescription(sampleBuffer)
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            if format.map(Self.isExpected) != true {
                rejected = true
                Self.logger.error(
                    "unexpected capture format: \(format?.mSampleRate ?? 0, privacy: .public) Hz, \(format?.mChannelsPerFrame ?? 0, privacy: .public) ch, \(format?.mBitsPerChannel ?? 0, privacy: .public) bit"
                )
                onLoss()
            }
        }
        guard !rejected else { return }
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let data = list.mBuffers.mData else { return }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
        withExtendedLifetime(blockBuffer) { sink.consume(id, samples) }
    }
}

/// Cancels a task when released, so the actor needs no deinit.
private final class TaskCancellation: Sendable {
    private let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) {
        self.task = task
    }

    deinit {
        task.cancel()
    }
}

extension AudioCapture: AudioLevelSource {
    /// Nonisolated and synchronous: the hud reads it 30 times a second and must never queue behind a start or a stop
    /// on the actor. It takes the sink's lock for a few loads and stores.
    public nonisolated func takeLevel() -> LevelReading? {
        sink.takeLevel()
    }
}

extension AudioCapture: AudioWindowSource {
    /// Nonisolated for the same reason as `takeLevel`. Copies at most `count` samples under the sink's lock.
    public nonisolated func window(count: Int, at now: ContinuousClock.Instant) -> [Float]? {
        sink.window(count: count, at: now)
    }
}

extension AudioCapture: AudioTailSource {
    /// Nonisolated for the same reason as `takeLevel`. Copies at most `maxSamples` samples under the sink's lock,
    /// once per live-text decode.
    public nonisolated func takeTail(maxSamples: Int, minimumRMS: Float) -> [Float]? {
        sink.takeTail(maxSamples: maxSamples, minimumRMS: minimumRMS)
    }
}

/// Shared by the actor and the sample queue. All state sits behind one unfair lock.
final class CaptureSink: @unchecked Sendable {
    private struct State {
        var id: UtteranceID?
        var buffer: SampleBuffer
        var finished = false
        var firstBuffer: OSSignpostIntervalState?
        var armedAt: ContinuousClock.Instant?
        var taps = TapStats()
        /// When the newest sample buffer landed and how many samples it added: where `PlayoutCursor` starts from.
        var lastBuffer: (at: ContinuousClock.Instant, samples: Int)?
    }

    /// The sample buffers of one utterance, logged at disarm: their size on a Bluetooth microphone is a premise of the
    /// hud's level reads that is measured live.
    private struct TapStats {
        var count = 0
        var smallest = Int.max
        var largest = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let continuation: AsyncStream<AudioInputEvent>.Continuation
    private let signposter = OSSignposter(subsystem: HarkLog.subsystem, category: "audio")
    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "audio")

    init(maxDuration: Duration, continuation: AsyncStream<AudioInputEvent>.Continuation) {
        state = OSAllocatedUnfairLock(uncheckedState: State(buffer: SampleBuffer(maxDuration: maxDuration)))
        self.continuation = continuation
    }

    func arm(_ id: UtteranceID) {
        let interval = signposter.beginInterval("startToFirstBuffer", id: signposter.makeSignpostID())
        state.withLockUnchecked { state in
            state.id = id
            state.buffer.reset()
            state.finished = false
            state.firstBuffer = interval
            state.armedAt = .now
            state.taps = TapStats()
            state.lastBuffer = nil
        }
    }

    func disarm() -> CapturedAudio {
        let (audio, taps) = state.withLockUnchecked { state in
            let audio = CapturedAudio(summary: state.buffer.summary(), samples: state.buffer.samples)
            state.id = nil
            state.buffer.reset()
            state.firstBuffer = nil
            return (audio, state.taps)
        }
        if taps.count > 0 {
            Self.logger.info(
                "tap buffers \(taps.count, privacy: .public), \(taps.smallest, privacy: .public)-\(taps.largest, privacy: .public) frames at \(Int(SampleBuffer.sampleRate), privacy: .public) Hz"
            )
        }
        return audio
    }

    /// The spectrum's window at `now`; nil when no capture is armed or no buffer has landed.
    func window(count: Int, at now: ContinuousClock.Instant) -> [Float]? {
        state.withLockUnchecked { state in
            guard state.id != nil, let last = state.lastBuffer else { return nil }
            let end = PlayoutCursor.end(
                newest: state.buffer.samples.count, lastBuffer: last.samples, elapsed: last.at.duration(to: now))
            return state.buffer.window(endingAt: end, count: count)
        }
    }

    /// The loudest 20 ms since the last read; nil when no capture is armed.
    func takeLevel() -> LevelReading? {
        state.withLockUnchecked { state in
            state.id == nil ? nil : state.buffer.takeLevel()
        }
    }

    /// The live text's tail; nil when no capture is armed or nothing rose to `minimumRMS` since the last take.
    func takeTail(maxSamples: Int, minimumRMS: Float) -> [Float]? {
        state.withLockUnchecked { state in
            state.id == nil ? nil : state.buffer.takeTail(maxSamples: maxSamples, minimumRMS: minimumRMS)
        }
    }

    func report(_ event: AudioInputEvent) {
        continuation.yield(event)
    }

    /// Sample queue: the 16 kHz mono samples of one sample buffer of utterance `id`. A buffer of an utterance that is
    /// no longer armed, a late one from a session being stopped, is dropped.
    func consume(_ id: UtteranceID, _ samples: some Collection<Float>) {
        let event: AudioInputEvent? = state.withLockUnchecked { state in
            guard state.id == id, !state.finished else { return nil }
            state.taps.count += 1
            state.taps.smallest = min(state.taps.smallest, samples.count)
            state.taps.largest = max(state.taps.largest, samples.count)
            if let interval = state.firstBuffer {
                signposter.endInterval("startToFirstBuffer", interval)
                state.firstBuffer = nil
                if let armedAt = state.armedAt {
                    let elapsed = armedAt.duration(to: .now)
                    Self.logger.info(
                        "first buffer \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
                }
            }
            let before = state.buffer.samples.count
            let filled = state.buffer.append(samples)
            let added = state.buffer.samples.count - before
            if added > 0 { state.lastBuffer = (.now, added) }
            guard filled else { return nil }
            state.finished = true
            return .reachedMaxDuration(id, state.buffer.summary())
        }
        if let event { continuation.yield(event) }
    }
}
