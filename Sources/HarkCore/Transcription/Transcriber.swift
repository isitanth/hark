import Foundation
import os
import whisper

/// whisper.cpp behind `TranscriptionEngine`.
///
/// The actor owns the policy: which language, which prompt, when to load, when to let go. The C context itself
/// lives in `Session` and is only ever reached from `queue`, one serial queue. Two reasons, both hard: whisper is
/// explicitly not thread safe for a single context, and `whisper_full` blocks for hundreds of milliseconds, which
/// is not something to do to a cooperative thread. Loading and decoding happen inside the same queue block, so an
/// idle unload can never land between them.
public actor Transcriber: TranscriptionEngine {
    /// The model this transcriber decodes with. A different model means a different `Transcriber`.
    public let model: ModelInstallation
    /// Free the context after this long with no decode, or nil to keep it resident.
    ///
    /// Resident is the fast answer — a reload pays the load and the warm-up again, which is most of a second —
    /// so it is off by default and worth turning on for `large-v3`, whose weights alone are about a gigabyte.
    public let idleUnload: Duration?

    public private(set) var language: TranscriptionLanguage
    public private(set) var vocabulary: [String]
    /// What the last completed decode did. Nil until one has, and untouched by a decode that was aborted.
    ///
    /// It exists because the numbers that matter in this milestone — `audio_ctx`, the padded sample count, the
    /// decode time — are otherwise only visible in Console. M2's benchmark matrix reads them from here.
    public private(set) var lastDecode: DecodeReport?

    private let filter: HallucinationFilter
    private let session = Session()
    private let abortSignal = AbortSignal()
    private let queue = DispatchQueue(label: "\(HarkLog.subsystem).whisper", qos: .userInitiated)
    private let signposter = OSSignposter(subsystem: HarkLog.subsystem, category: "transcriber")

    /// Set by `shutdown`. Checked on entry to every call that could load the model, before its first suspension, so a
    /// call that got in first is queued ahead of the shutdown's unload and one that did not refuses.
    private var closed = false
    /// Bumped by every decode. An idle task only unloads when the generation it was scheduled for is still current.
    private var idleGeneration: UInt64 = 0
    private var idleTask: Task<Void, Never>?

    fileprivate static let logger = Logger(subsystem: HarkLog.subsystem, category: "transcriber")

    public init(
        model: ModelInstallation,
        language: TranscriptionLanguage,
        vocabulary: [String] = [],
        idleUnload: Duration? = nil,
        thresholds: HallucinationFilter.Thresholds = .standard
    ) {
        self.model = model
        self.language = language
        self.vocabulary = vocabulary
        self.idleUnload = idleUnload
        self.filter = HallucinationFilter(thresholds: thresholds)
    }

    // MARK: Lifecycle

    /// Loads the model and warms it up. `transcribe` does this on demand; call it to pay the cost up front.
    public func prepare() async throws(PipelineFailure) {
        guard !closed else { throw .quitting }
        let model = self.model
        let language = self.language
        let signposter = self.signposter
        let loaded = await onQueue { $0.load(model, language: language, signposter: signposter) }
        guard loaded else { throw .modelLoad }
        scheduleIdleUnload()
    }

    /// Frees the context for good: nothing loads again. The unload runs on the whisper queue, behind any decode or load
    /// already there.
    public func shutdown() async {
        closed = true
        await unload()
    }

    /// Frees the context. The next `transcribe` loads and warms up again.
    public func unload() async {
        idleTask?.cancel()
        idleTask = nil
        await onQueue { $0.unload() }
    }

    /// Whether the weights are resident. The Model tab refuses to delete a model that is.
    public func isLoaded() async -> Bool {
        await onQueue { $0.isLoaded }
    }

    /// Language and vocabulary are per-decode parameters, so changing either costs nothing and forces no reload.
    public func set(language: TranscriptionLanguage) {
        self.language = language
    }

    public func set(vocabulary: [String]) {
        self.vocabulary = vocabulary
    }

    // MARK: TranscriptionEngine

    public func transcribe(_ samples: [Float]) async throws(PipelineFailure) -> Transcript {
        guard !closed else { throw .quitting }
        idleTask?.cancel()
        let chunks = ClipChunks.ranges(for: samples)
        let request = Request(
            language: language, vocabulary: vocabulary, filter: filter, generation: abortSignal.begin())
        let model = self.model
        let signal = self.abortSignal
        let signposter = self.signposter

        let outcome = await onQueue { session in
            guard session.load(model, language: request.language, signposter: signposter) else {
                return Outcome.loadFailed
            }
            return session.run(samples, in: chunks, request, signal: signal, signposter: signposter)
        }
        scheduleIdleUnload()

        switch outcome {
        case .loadFailed:
            throw .modelLoad
        case .decodeFailed(let code):
            Self.logger.error("whisper_full failed with \(code)")
            throw .transcription(code: code)
        case .aborted:
            Self.logger.debug("decode aborted")
            return Transcript(raw: "", tier: model.tier)
        case .decoded(let pieces):
            return judge(pieces)
        }
    }

    /// Arms the abort flag. whisper checks it between graph computes, so an in-flight `whisper_full` returns early.
    public func cancel() async {
        abortSignal.abort()
    }

    // MARK: Internals

    /// The transcript, or a blank one when the filter says whisper was talking to itself. Blank is what makes the
    /// pipeline log `discarded / empty_transcript` instead of resolving an invented command. Each chunk of a long
    /// clip was judged on its own as it was decoded; the chunks kept are joined.
    ///
    /// Nothing here logs the text: `raw_text` belongs to the JSONL log, which is the one place it is written.
    private func judge(_ pieces: [Piece]) -> Transcript {
        let decoded = pieces.compactMap(\.decoded)
        let kept = pieces.filter(\.isKept)
        let noSpeechProbability = decoded.map(\.noSpeechProbability).max() ?? 1
        let languageCode = (kept.first?.decoded ?? decoded.first)?.languageCode ?? ""
        let ms = decoded.reduce(0) { $0 + $1.ms }
        Self.logger.info(
            """
            decoded \(decoded.reduce(0) { $0 + $1.text.count }) chars in \(ms) ms, \
            audio_ctx \(decoded.last?.audioContext ?? 0), lang \(languageCode, privacy: .public), \
            no_speech \(noSpeechProbability, format: .fixed(precision: 2))
            """)
        if pieces.count > 1 {
            Self.logger.info("chunks kept \(kept.count) of \(pieces.count), \(pieces.count - decoded.count) silent")
        }
        let rejection: HallucinationFilter.Rejection? =
            kept.isEmpty ? pieces.lazy.compactMap(\.rejection).first ?? .blank : nil
        lastDecode = DecodeReport(
            sampleCount: decoded.reduce(0) { $0 + $1.sampleCount },
            audioContext: decoded.last?.audioContext ?? 0,
            segments: decoded.reduce(0) { $0 + $1.segments },
            chunks: pieces.count,
            keptChunks: kept.count,
            noSpeechProbability: noSpeechProbability,
            languageCode: languageCode,
            ms: ms,
            rejection: rejection)

        if let rejection {
            Self.logger.info("rejected as \(rejection.rawValue, privacy: .public)")
            return Transcript(raw: "", tier: model.tier)
        }
        return Transcript(raw: kept.compactMap(\.text).joined(separator: " "), tier: model.tier)
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = nil
        guard let idleUnload else { return }
        idleGeneration += 1
        let generation = idleGeneration
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: idleUnload)
            guard !Task.isCancelled else { return }
            await self?.unloadIfStillIdle(generation)
        }
    }

    private func unloadIfStillIdle(_ generation: UInt64) async {
        guard generation == idleGeneration else { return }
        Self.logger.info("unloading after \(String(describing: self.idleUnload), privacy: .public) idle")
        await unload()
    }

    /// Runs `body` against the session on the serial queue. The closure is `@Sendable`, so it can only close over
    /// values, never over the actor.
    private func onQueue<R: Sendable>(_ body: @escaping @Sendable (Session) -> R) async -> R {
        let session = self.session
        let queue = self.queue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body(session))
            }
        }
    }

    public struct DecodeReport: Sendable, Equatable {
        /// Samples handed to whisper, after `SamplePadding`, over every chunk decoded.
        public let sampleCount: Int
        public let audioContext: Int
        public let segments: Int
        /// The pieces `ClipChunks` cut the clip into: one unless it was longer than whisper's window.
        public let chunks: Int
        /// Chunks the filter kept: 0 when the transcript is blank.
        public let keptChunks: Int
        public let noSpeechProbability: Double
        /// The language whisper decoded in, which under `.auto` is the one it detected.
        public let languageCode: String
        public let ms: Int
        /// Why `HallucinationFilter` blanked the transcript, or nil when the text was kept.
        public let rejection: HallucinationFilter.Rejection?
    }

    /// What every chunk of one clip is decoded with.
    private struct Request: Sendable {
        let language: TranscriptionLanguage
        let vocabulary: [String]
        let filter: HallucinationFilter
        let generation: UInt64
    }

    /// One `whisper_full` call.
    private struct Decoded: Sendable {
        let text: String
        let noSpeechProbability: Double
        /// Mean RMS of the chunk as captured, before padding. The filter's evidence that the room was quiet.
        let audioLevel: Double
        let sampleCount: Int
        let audioContext: Int
        let segments: Int
        let languageCode: String
        let ms: Int
    }

    /// One chunk and its verdict. `decoded` is nil for a chunk of a long clip that was silence throughout.
    private struct Piece: Sendable {
        let decoded: Decoded?
        let verdict: HallucinationFilter.Verdict

        var isKept: Bool { text != nil }
        var text: String? { if case .keep(let text) = verdict { text } else { nil } }
        var rejection: HallucinationFilter.Rejection? {
            if case .reject(let rejection) = verdict { rejection } else { nil }
        }
    }

    private enum Outcome: Sendable {
        case decoded([Piece])
        /// We asked for it, so it is not a failure.
        case aborted
        case loadFailed
        case decodeFailed(Int32)
    }

    private enum Decode: Sendable {
        case decoded(Decoded)
        case aborted
        case loadFailed
        case decodeFailed(Int32)
    }

    /// The in-flight decode's abort flag.
    ///
    /// `whisper_full` calls `abort_callback` between graph computes, on whichever thread ggml is running. That is
    /// C, not Swift concurrency: the callback cannot hop to an actor and cannot allocate, so the flag is a plain
    /// unfair lock reached through `abort_callback_user_data`.
    ///
    /// The generation is what keeps a stale cancel from killing the next utterance: `cancel()` arriving between
    /// two decodes sets a flag that the next `begin()` clears.
    ///
    /// This holds only while one decode is in flight at a time, which `PipelineController` guarantees — a press
    /// arriving mid-transcription is reduced to `busy` and never reaches here. The invariant is load-bearing:
    /// because `begin()` runs on the actor before the queue hop, two overlapping `transcribe` calls would let
    /// the second one clear the first one's pending abort, and leave the first reporting `decodeFailed` rather
    /// than `aborted`. M7's always-on mode is where that assumption is worth revisiting; a per-decode token
    /// handed to the callback would remove the shared flag entirely.
    private final class AbortSignal: Sendable {
        private struct State {
            var generation: UInt64 = 0
            var aborted = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        /// Opens the window for a new decode and returns its generation.
        func begin() -> UInt64 {
            state.withLock { state in
                state.generation += 1
                state.aborted = false
                return state.generation
            }
        }

        func abort() {
            state.withLock { $0.aborted = true }
        }

        /// whisper's thread.
        var isAborted: Bool {
            state.withLock { $0.aborted }
        }

        func aborted(_ generation: UInt64) -> Bool {
            state.withLock { $0.generation == generation && $0.aborted }
        }
    }

    /// whisper's context and what is derived from it. Only ever touched on `Transcriber.queue`, which is the whole
    /// of the `@unchecked` claim.
    private final class Session: @unchecked Sendable {
        private var context: OpaquePointer?
        /// `whisper_model_n_audio_ctx` for the loaded model: the ceiling `DecodeSpec` clamps to.
        private var modelAudioContext = DecodeSpec.fullAudioContext
        /// Whether whisper will use the Core ML encoder, which pins `audio_ctx` to the full window.
        private var usesCoreMLEncoder = false

        var isLoaded: Bool { context != nil }

        deinit {
            // The queue's blocks hold the last references to this, so nothing can be mid-decode here.
            if let context {
                whisper_free(context)
            }
        }

        /// Loads the weights and warms them up. False means whisper could not open the file.
        func load(_ model: ModelInstallation, language: TranscriptionLanguage, signposter: OSSignposter) -> Bool {
            guard context == nil else { return true }
            WhisperRuntime.redirectLogging()

            var parameters = whisper_context_default_params()
            parameters.use_gpu = true
            parameters.flash_attn = true

            let interval = signposter.beginInterval("load", id: signposter.makeSignpostID())
            defer { signposter.endInterval("load", interval) }
            let started = ContinuousClock.now
            let path = model.weights.path(percentEncoded: false)
            guard let loaded = whisper_init_from_file_with_params(path, parameters) else {
                Transcriber.logger.error("whisper could not load \(path, privacy: .public)")
                return false
            }
            context = loaded
            modelAudioContext = Int(whisper_model_n_audio_ctx(loaded))
            usesCoreMLEncoder = reportCoreML(model)

            let loadMs = started.duration(to: .now).wholeMilliseconds
            let warmUpMs = warmUp(language: language)
            Transcriber.logger.info(
                """
                loaded \(model.tier.rawValue, privacy: .public) in \(loadMs) ms, warm-up \(warmUpMs) ms, \
                n_audio_ctx \(self.modelAudioContext)
                """)
            return true
        }

        func unload() {
            guard let context else { return }
            whisper_free(context)
            self.context = nil
            Transcriber.logger.info("unloaded")
        }

        /// Each chunk decoded on its own, in order, and judged as it comes. A chunk of a clip longer than the window
        /// that is silence throughout is not decoded; a shorter clip was already weighed whole by `CapturePolicy`. Under `.auto`, the first chunk kept sets the language of the rest: left to
        /// detect again, a later chunk drifted into English.
        func run(
            _ samples: [Float], in chunks: [Range<Int>], _ request: Request, signal: AbortSignal,
            signposter: OSSignposter
        ) -> Outcome {
            var language = request.language
            var pieces: [Piece] = []
            for chunk in chunks {
                guard !signal.aborted(request.generation) else { return .aborted }
                let clip = samples[chunk]
                if samples.count > ClipChunks.maximumSampleCount, ClipChunks.peakRMS(clip) < ClipChunks.quietRMS {
                    pieces.append(Piece(decoded: nil, verdict: .reject(.blank)))
                    continue
                }
                switch decode(clip, language: language, request, signal: signal, signposter: signposter) {
                case .decoded(let decoded):
                    let verdict = request.filter.verdict(
                        for: decoded.text, noSpeechProbability: decoded.noSpeechProbability,
                        audioLevel: decoded.audioLevel)
                    if language == .auto, case .keep = verdict,
                        let detected = TranscriptionLanguage(rawValue: decoded.languageCode)
                    {
                        language = detected
                    }
                    pieces.append(Piece(decoded: decoded, verdict: verdict))
                case .aborted:
                    return .aborted
                case .loadFailed:
                    return .loadFailed
                case .decodeFailed(let code):
                    return .decodeFailed(code)
                }
            }
            return .decoded(pieces)
        }

        private func decode(
            _ clip: ArraySlice<Float>, language: TranscriptionLanguage, _ request: Request, signal: AbortSignal,
            signposter: OSSignposter
        ) -> Decode {
            guard let context else { return .loadFailed }
            // Measured before padding: padding to the 1.25 s floor is silence, and averaging it in would drag a
            // short real utterance under the quiet threshold.
            let audioLevel = Transcriber.meanRMS(clip)
            let samples = SamplePadding.padded(Array(clip))
            let spec = DecodeSpec(
                sampleCount: samples.count,
                language: language,
                vocabulary: request.vocabulary,
                modelAudioContext: modelAudioContext,
                usesCoreMLEncoder: usesCoreMLEncoder)

            let interval = signposter.beginInterval("decode", id: signposter.makeSignpostID())
            let started = ContinuousClock.now
            let code = Self.withParameters(spec) { parameters in
                parameters.abort_callback = { data in
                    guard let data else { return false }
                    return Unmanaged<AbortSignal>.fromOpaque(data).takeUnretainedValue().isAborted
                }
                parameters.abort_callback_user_data = Unmanaged.passUnretained(signal).toOpaque()
                return samples.withUnsafeBufferPointer { samples in
                    whisper_full(context, parameters, samples.baseAddress, Int32(samples.count))
                }
            }
            let ms = started.duration(to: .now).wholeMilliseconds
            signposter.endInterval("decode", interval)

            // Checked before the return code: an abort surfaces as a failed compute, and a decode that finished
            // just as the user cancelled is still one they asked us to throw away.
            guard !signal.aborted(request.generation) else { return .aborted }
            guard code == 0 else { return .decodeFailed(code) }

            let segments = whisper_full_n_segments(context)
            var text = ""
            var noSpeechProbability = 0.0
            for segment in 0..<segments {
                if let characters = whisper_full_get_segment_text(context, segment) {
                    text += String(cString: characters)
                }
                let probability = whisper_full_get_segment_no_speech_prob(context, segment)
                noSpeechProbability = max(noSpeechProbability, Double(probability))
            }
            return .decoded(
                Decoded(
                    text: text,
                    // No segment means no probability to read. The filter rejects blank text on its own, but
                    // "whisper heard nothing" is the honest value to report alongside it.
                    noSpeechProbability: segments == 0 ? 1 : noSpeechProbability,
                    audioLevel: audioLevel,
                    sampleCount: samples.count,
                    audioContext: spec.audioContext,
                    segments: Int(segments),
                    languageCode: Self.languageCode(context),
                    ms: ms))
        }

        /// One decode over silence at load time, so the first real utterance does not pay for Metal pipeline
        /// compilation and the Core ML encoder's first load. Returns the milliseconds it took.
        ///
        /// `max_tokens = 1` stops the decoder writing a whole invented sentence about the silence: one step is
        /// enough to build every graph. The clip is the padding floor, which is also the shortest one a real
        /// utterance can produce, so the warm-up compiles the shapes the first press will ask for.
        private func warmUp(language: TranscriptionLanguage) -> Int {
            guard let context else { return 0 }
            let spec = DecodeSpec(
                sampleCount: SamplePadding.minimumSampleCount,
                language: language,
                modelAudioContext: modelAudioContext,
                usesCoreMLEncoder: usesCoreMLEncoder)
            let silence = [Float](repeating: 0, count: SamplePadding.minimumSampleCount)
            let started = ContinuousClock.now
            let code = Self.withParameters(spec) { parameters in
                parameters.max_tokens = 1
                return silence.withUnsafeBufferPointer { samples in
                    whisper_full(context, parameters, samples.baseAddress, Int32(samples.count))
                }
            }
            if code != 0 {
                Transcriber.logger.error("warm-up decode failed with \(code)")
            }
            return started.duration(to: .now).wholeMilliseconds
        }

        /// Whether whisper will find a Core ML encoder for this model, which decides `audio_ctx`.
        ///
        /// whisper.cpp takes no Core ML path: it derives one from the weights and uses it if it is there. A
        /// mismatch is silent at runtime — the encoder just runs on Metal instead — so it is worth a log line.
        private func reportCoreML(_ model: ModelInstallation) -> Bool {
            let derived = ModelInstallation.coreMLEncoderURL(for: model.weights)
            let present = FileManager.default.fileExists(atPath: derived.path(percentEncoded: false))
            if model.coreMLEncoder != nil, !present {
                Transcriber.logger.error(
                    "core ml encoder installed but whisper looks at \(derived.lastPathComponent, privacy: .public)")
            } else {
                Transcriber.logger.info("core ml encoder \(present ? "present" : "absent", privacy: .public)")
            }
            return present
        }

        private static func languageCode(_ context: OpaquePointer) -> String {
            let id = whisper_full_lang_id(context)
            guard id >= 0, let characters = whisper_lang_str(id) else { return "?" }
            return String(cString: characters)
        }

        /// Every field of `whisper_full_params` Hark sets, from `DecodeSpec` and nothing else.
        ///
        /// `language` and `initial_prompt` are borrowed pointers that whisper reads during `whisper_full`, so the
        /// strings behind them have to outlive the call: they are only valid inside the `withCString` bodies,
        /// which is why the decode happens inside `body` rather than after a returned struct.
        private static func withParameters<R>(_ spec: DecodeSpec, _ body: (inout whisper_full_params) -> R) -> R {
            var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            parameters.n_threads = Int32(spec.threadCount)
            parameters.translate = spec.translate
            parameters.no_context = spec.noContext
            parameters.no_timestamps = spec.noTimestamps
            parameters.single_segment = spec.singleSegment
            parameters.print_special = spec.printSpecial
            parameters.print_progress = spec.printProgress
            parameters.print_realtime = spec.printRealtime
            parameters.print_timestamps = spec.printTimestamps
            parameters.token_timestamps = spec.tokenTimestamps
            parameters.audio_ctx = Int32(spec.audioContext)
            parameters.suppress_blank = spec.suppressBlank
            parameters.suppress_nst = spec.suppressNonSpeechTokens
            parameters.temperature = spec.temperature
            parameters.temperature_inc = spec.temperatureIncrement
            parameters.no_speech_thold = spec.noSpeechThreshold
            parameters.greedy.best_of = Int32(spec.bestOf)

            return spec.language.whisperCode.withCString { languageCode in
                parameters.language = languageCode
                // Auto-detection is `language = "auto"`. `detect_language` means detect and stop, which is not
                // what any of this wants.
                parameters.detect_language = false
                guard let prompt = spec.initialPrompt else { return body(&parameters) }
                return prompt.withCString { initialPrompt in
                    parameters.initial_prompt = initialPrompt
                    return body(&parameters)
                }
            }
        }
    }
}

extension Transcriber {
    /// Root mean square of the clip. Matches `SampleBuffer`'s own measure, so the number the filter sees is the
    /// one M1's capture policy would have reported.
    fileprivate static func meanRMS(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }
}

extension Duration {
    fileprivate var wholeMilliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
