import Foundation
import os

/// The real `LLMTransport`: one ephemeral URLSession, no cache, no cookies, no waiting for connectivity. Its
/// 60 s request timeout is only a backstop; the client's own timers on its clock are the limits that count.
public struct URLSessionLLMTransport: LLMTransport {
    /// A body piece ends at each LF, so an SSE line reaches the parser as soon as it is whole, or at this size.
    static let pieceLimit = 16 * 1024

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws(LLMTransportError) -> LLMHTTPResponse {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: RedirectRefusal())
        } catch {
            throw Self.transportError(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let source = ByteSource(bytes: bytes)
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let reader = Task {
                var piece = Data()
                do {
                    for try await byte in source.bytes {
                        piece.append(byte)
                        if byte == UInt8(ascii: "\n") || piece.count >= Self.pieceLimit {
                            continuation.yield(piece)
                            piece = Data()
                        }
                    }
                    if !piece.isEmpty { continuation.yield(piece) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.transportError(error))
                }
            }
            // Cancelling the URLSession task closes the connection, which is what makes MTPLX stop generating.
            continuation.onTermination = { _ in
                reader.cancel()
                source.bytes.task.cancel()
            }
        }
        return LLMHTTPResponse(status: status, body: body)
    }

    static func transportError(_ error: any Error) -> LLMTransportError {
        if error is CancellationError { return .cancelled }
        guard let error = error as? URLError else { return .other(code: (error as NSError).code) }
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
            .networkConnectionLost, .secureConnectionFailed, .cannotLoadFromNetwork:
            return .unreachable
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        default: return .other(code: error.code.rawValue)
        }
    }
}

/// `AsyncBytes` is not `Sendable`; the one reader task that iterates it is the only user, and the termination
/// handler touches only its URLSession task.
private struct ByteSource: @unchecked Sendable {
    let bytes: URLSession.AsyncBytes
}

/// Refuses every redirect: a key goes only to the host the profile names. The 3xx then arrives as the status.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// Streams one chat completion from an OpenAI-compatible endpoint or Anthropic's Messages API, and lists its models.
/// The key comes from the secret store per call and goes only into the header the profile's dialect reads,
/// `Authorization` or `x-api-key`; the timers run on the injected clock.
public actor LLMClient {
    /// The Messages API version every Anthropic request names.
    static let anthropicVersion = "2023-06-01"
    /// The beta that lets a request declined by Claude's safety filters be answered by the recommended fallback model,
    /// in the same stream (`fallbacks: "default"`).
    static let anthropicFallbackBeta = "server-side-fallback-2026-07-01"

    /// The most of a non-200 body read for its message.
    static let errorBodyLimit = 64 * 1024
    /// The most of a `/models` body read.
    static let modelsBodyLimit = 1024 * 1024

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "llm")

    private let transport: any LLMTransport
    private let secrets: any SecretStore
    private let clock: any Clock<Duration>
    /// For a server on this Mac.
    private let timeouts: LLMTimeouts
    /// For a server elsewhere, Anthropic's API among them.
    private let remoteTimeouts: LLMTimeouts

    public init(
        transport: any LLMTransport = URLSessionLLMTransport(), secrets: any SecretStore,
        clock: any Clock<Duration> = ContinuousClock(), timeouts: LLMTimeouts = .standard,
        remoteTimeouts: LLMTimeouts = .remote
    ) {
        self.transport = transport
        self.secrets = secrets
        self.clock = clock
        self.timeouts = timeouts
        self.remoteTimeouts = remoteTimeouts
    }

    private nonisolated func limits(for profile: ProviderProfile) -> LLMTimeouts {
        profile.isLoopback ? timeouts : remoteTimeouts
    }

    /// `text` pieces, then exactly one `finished` or `failed`, then the end. When the consumer stops iterating, the
    /// request is cancelled and nothing more is sent.
    public nonisolated func complete(
        _ messages: [ChatMessage], model: String, profile: ProviderProfile
    ) -> AsyncStream<LLMEvent> {
        AsyncStream { continuation in
            let task = Task { await self.run(messages, model: model, profile: profile, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The ids `GET {base_url}/models` lists, in order, within the connect limit for the head and the probe limit
    /// for the whole call.
    public func models(profile: ProviderProfile) async -> Result<[String], LLMFailure> {
        await listing(profile: profile).map { $0.map(\.id) }
    }

    /// `models`, with what each entry says of images: MTPLX's `supports_vision` and `modalities.input`, llama.cpp's
    /// and OpenRouter's `architecture.input_modalities`, Anthropic's `capabilities.image_input.supported`.
    public func listing(profile: ProviderProfile) async -> Result<[LLMModelListing], LLMFailure> {
        let key: String?
        switch await resolveKey(for: profile) {
        case .success(let value): key = value
        case .failure(let failure): return .failure(failure)
        }
        var request = URLRequest(url: profile.baseURL.appending(path: "models"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.authorize(&request, profile: profile, key: key)
        let answer = await exchange(request, limits: limits(for: profile), unreachable: profile.unreachable)
        switch answer {
        case .failure(let failure):
            return .failure(failure)
        case .success((401, _)):
            return .failure(.keyRefused)
        case .success((200, let body)):
            guard let wire = try? JSONDecoder().decode(ModelsWire.self, from: body) else {
                return .failure(.server(status: 200, message: nil))
            }
            return .success(wire.data.map { LLMModelListing(id: $0.id, vision: $0.vision) })
        case .success((let status, let body)):
            return .failure(.server(status: status, message: LLMErrorBody.message(in: body)))
        }
    }

    // MARK: - The key and the request

    /// Nil for a profile that takes no key. A Keychain error reads as no key: either way no request can be sent.
    private nonisolated func resolveKey(for profile: ProviderProfile) async -> Result<String?, LLMFailure> {
        guard profile.key == .keychain else { return .success(nil) }
        do {
            guard let key = try await secrets.secret(for: profile.name), !key.isEmpty else { return .failure(.noKey) }
            return .success(key)
        } catch {
            Self.logger.error("keychain read for \(profile.name, privacy: .public) failed: \(error.status)")
            return .failure(.noKey)
        }
    }

    /// The key in the header the dialect reads: `Authorization: Bearer` for OpenAI; `x-api-key` and the API version
    /// for Anthropic.
    static func authorize(_ request: inout URLRequest, profile: ProviderProfile, key: String?) {
        switch profile.api {
        case .openAI:
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            if let key { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        }
    }

    /// Nil when the body cannot be written as JSON: a number that is not finite, which no parsed profile holds.
    static func chatRequest(
        _ messages: [ChatMessage], model: String, profile: ProviderProfile, key: String?
    ) -> URLRequest? {
        let path = profile.api == .anthropic ? "messages" : "chat/completions"
        var request = URLRequest(url: profile.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authorize(&request, profile: profile, key: key)
        let body: [String: Any]
        switch profile.api {
        case .openAI:
            body = openAIBody(messages, model: model, profile: profile)
        case .anthropic:
            request.setValue(anthropicFallbackBeta, forHTTPHeaderField: "anthropic-beta")
            body = anthropicBody(messages, model: model, profile: profile)
        }
        guard JSONSerialization.isValidJSONObject(body),
            let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        else { return nil }
        request.httpBody = data
        return request
    }

    private static func openAIBody(_ messages: [ChatMessage], model: String, profile: ProviderProfile) -> [String: Any]
    {
        // `extra` first and the standard fields over it: the parser refuses a standard name in `extra`, and a profile
        // built in code cannot turn streaming off or ask for JSON either. A server off this Mac gets the standard
        // fields only: `extra` is for the local server's own switches, and a cloud API may refuse what it does not know.
        var body: [String: Any] = [:]
        for (name, value) in profile.isLoopback ? profile.extra : [:] {
            switch value {
            case .bool(let flag): body[name] = flag
            case .int(let number): body[name] = number
            case .double(let number): body[name] = number
            case .string(let text): body[name] = text
            }
        }
        body["model"] = model
        body["messages"] = messages.map { ["role": $0.role.rawValue, "content": openAIContent($0)] }
        body["stream"] = true
        body["max_tokens"] = profile.maxTokens
        body["temperature"] = profile.temperature
        body["response_format"] = nil
        body["stream_options"] = nil
        return body
    }

    /// The system messages go to the top-level `system`. No sampling setting, which Claude's current models refuse,
    /// and no `thinking`: left out, each model thinks the way it does by default.
    private static func anthropicBody(
        _ messages: [ChatMessage], model: String, profile: ProviderProfile
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.filter { $0.role != .system }.map {
                ["role": $0.role.rawValue, "content": anthropicContent($0)]
            },
            "stream": true,
            "max_tokens": profile.maxTokens,
            "fallbacks": "default",
        ]
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        if !system.isEmpty { body["system"] = system }
        if let effort = profile.effort { body["output_config"] = ["effort": effort.rawValue] }
        return body
    }

    /// A message of text alone is the plain string it always was; one with an image is an array, the image first, as
    /// Anthropic's vision guide asks and the Qwen template takes in any order. MTPLX reads only a `;base64` data URL.
    static func openAIContent(_ message: ChatMessage) -> Any {
        guard message.hasImage else { return message.content }
        return imageFirst(message.parts).map { part -> [String: Any] in
            switch part {
            case .text(let text): ["type": "text", "text": text]
            case .image(let image):
                [
                    "type": "image_url",
                    "image_url": ["url": "data:\(image.mediaType);base64," + image.data.base64EncodedString()],
                ]
            }
        }
    }

    /// Anthropic's image block carries the bare base64 and its media type, no `data:` prefix.
    static func anthropicContent(_ message: ChatMessage) -> Any {
        guard message.hasImage else { return message.content }
        return imageFirst(message.parts).map { part -> [String: Any] in
            switch part {
            case .text(let text): ["type": "text", "text": text]
            case .image(let image):
                [
                    "type": "image",
                    "source": [
                        "type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString(),
                    ] as [String: Any],
                ]
            }
        }
    }

    /// Images keep their order among themselves, texts among theirs.
    private static func imageFirst(_ parts: [ContentPart]) -> [ContentPart] {
        let images = parts.filter {
            guard case .image = $0 else { return false }
            return true
        }
        return images
            + parts.filter {
                guard case .text = $0 else { return false }
                return true
            }
    }

    /// `unreachable` is the profile's own: a server on this Mac to start, or a host elsewhere that cannot be reached.
    static func failure(_ error: LLMTransportError, unreachable: LLMFailure) -> LLMFailure {
        switch error {
        case .unreachable: unreachable
        case .timedOut: .noAnswer
        case .cancelled, .other: .server(status: nil, message: nil)
        }
    }

    // MARK: - The stream

    private nonisolated func run(
        _ messages: [ChatMessage], model: String, profile: ProviderProfile,
        continuation: AsyncStream<LLMEvent>.Continuation
    ) async {
        let key: String?
        switch await resolveKey(for: profile) {
        case .success(let value):
            key = value
        case .failure(let failure):
            continuation.yield(.failed(failure, LLMCallSummary(ms: nil)))
            continuation.finish()
            return
        }
        guard let request = Self.chatRequest(messages, model: model, profile: profile, key: key) else {
            Self.logger.error("the request for \(profile.name, privacy: .public) is not valid JSON; nothing was sent")
            continuation.yield(.failed(.server(status: nil, message: nil), LLMCallSummary(ms: nil)))
            continuation.finish()
            return
        }
        let decode: @Sendable (String) -> ChatStreamItem =
            switch profile.api {
            case .openAI: ChatStreamItem.init(data:)
            case .anthropic: MessagesStreamItem.item(data:)
            }
        let call = StreamCall(continuation: continuation, elapsed: clock.stopwatch(), decode: decode)
        // The timers start before the request, so a head that comes at once cannot stop a connect timer not yet set.
        let limits = limits(for: profile)
        let timers = CallTimers(clock: clock) { call.fail(.noAnswer) }
        timers.start(.total, after: limits.total)
        timers.start(.connect, after: limits.connect)
        let worker = Task { [transport] in
            await Self.stream(
                request, transport: transport, unreachable: profile.unreachable, silence: limits.silence, call: call,
                timers: timers)
        }
        call.attach(worker)
        await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        timers.stopAll()
        call.close()
    }

    private static func stream(
        _ request: URLRequest, transport: any LLMTransport, unreachable: LLMFailure, silence: Duration,
        call: StreamCall, timers: CallTimers
    ) async {
        let response: LLMHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            if error == .cancelled && Task.isCancelled { return }
            return call.fail(failure(error, unreachable: unreachable))
        }
        timers.stop(.connect)
        timers.start(.silence, after: silence)
        if response.status == 401 { return call.fail(.keyRefused) }
        guard response.status == 200 else {
            let body = await read(response.body, limit: errorBodyLimit) { timers.start(.silence, after: silence) }
            if Task.isCancelled { return }
            return call.fail(.server(status: response.status, message: LLMErrorBody.message(in: body)))
        }
        var parser = SSEParser()
        do {
            for try await piece in response.body {
                if call.receive(parser.feed(piece)) { return }
                // Any piece before the first word restarts the silence timer: a heartbeat, a progress chunk.
                if call.answered {
                    timers.stop(.silence)
                } else {
                    timers.start(.silence, after: silence)
                }
            }
        } catch {
            if Task.isCancelled { return }
            return call.fail(failure(error as? LLMTransportError ?? .other(code: 0), unreachable: unreachable))
        }
        if Task.isCancelled { return }
        if call.receive(parser.finish()) { return }
        call.complete()
    }

    /// At most `limit` bytes of `body`. A body cut by an error keeps what came before it.
    private static func read(
        _ body: AsyncThrowingStream<Data, any Error>, limit: Int, onPiece: () -> Void = {}
    ) async -> Data {
        var data = Data()
        do {
            for try await piece in body {
                data.append(piece.prefix(limit - data.count))
                if data.count >= limit { break }
                onPiece()
            }
        } catch {
            logger.info("error body cut after \(data.count) bytes")
        }
        return data
    }

    // MARK: - One whole exchange

    /// The status and the body of one request, the head within `connect` and the whole within `probe`.
    private func exchange(
        _ request: URLRequest, limits: LLMTimeouts, unreachable: LLMFailure
    ) async -> Result<(Int, Data), LLMFailure> {
        let handle = WorkerHandle()
        let timers = CallTimers(clock: clock) { handle.timeOut() }
        timers.start(.total, after: limits.probe)
        timers.start(.connect, after: limits.connect)
        let worker = Task { [transport] () -> Result<(Int, Data), LLMFailure> in
            let response: LLMHTTPResponse
            do {
                response = try await transport.send(request)
            } catch {
                return .failure(Self.failure(error as? LLMTransportError ?? .other(code: 0), unreachable: unreachable))
            }
            timers.stop(.connect)
            let body = await Self.read(response.body, limit: Self.modelsBodyLimit)
            handle.finish()
            return .success((response.status, body))
        }
        handle.attach { worker.cancel() }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        timers.stopAll()
        return handle.timedOut || Task.isCancelled ? .failure(.noAnswer) : result
    }
}

/// One streamed call's single ending. Whoever ends it first, the body, a timer or the consumer, wins; the events
/// after that go nowhere. `text` is yielded under the same lock, so no piece can follow the terminal event.
private final class StreamCall: Sendable {
    private struct State: Sendable {
        var ended = false
        var answered = false
        var summary = LLMCallSummary()
        var worker: Task<Void, Never>?
    }

    private let continuation: AsyncStream<LLMEvent>.Continuation
    private let elapsed: @Sendable () -> Duration
    /// One `data:` payload in the profile's dialect.
    private let decode: @Sendable (String) -> ChatStreamItem
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        continuation: AsyncStream<LLMEvent>.Continuation, elapsed: @escaping @Sendable () -> Duration,
        decode: @escaping @Sendable (String) -> ChatStreamItem
    ) {
        self.continuation = continuation
        self.elapsed = elapsed
        self.decode = decode
    }

    /// A piece of content has been sent.
    var answered: Bool { state.withLock { $0.answered } }

    /// The task that reads the response, cancelled when a timer ends the call.
    func attach(_ worker: Task<Void, Never>) {
        let ended = state.withLock { state -> Bool in
            state.worker = worker
            return state.ended
        }
        if ended { worker.cancel() }
    }

    /// The stream events in `data`, in order. True once one of them ended the call.
    func receive(_ data: [String]) -> Bool {
        for item in data.map(decode) {
            switch item {
            case .chunk(let chunk):
                let open = state.withLock { [continuation] state -> Bool in
                    guard !state.ended else { return false }
                    state.summary.model = chunk.model ?? state.summary.model
                    state.summary.finishReason = chunk.finishReason ?? state.summary.finishReason
                    state.summary.promptTokens = chunk.promptTokens ?? state.summary.promptTokens
                    state.summary.completionTokens = chunk.completionTokens ?? state.summary.completionTokens
                    if let content = chunk.content {
                        state.answered = true
                        continuation.yield(.text(content))
                    }
                    return true
                }
                if !open { return true }
            case .error(let message):
                fail(.server(status: nil, message: message))
                return true
            case .refused:
                fail(.refused)
                return true
            case .done:
                complete()
                return true
            case .unreadable:
                continue
            }
        }
        return false
    }

    /// The end of the body: finished with a word of content, empty without.
    func complete() {
        end { state in
            state.answered ? .finished(state.summary) : .failed(.empty, state.summary)
        }
    }

    func fail(_ failure: LLMFailure) {
        end { state in .failed(failure, state.summary) }
    }

    /// Ends the stream without an event, when nothing ended it: the consumer went away.
    func close() {
        end(nil)
    }

    private func end(_ event: (@Sendable (State) -> LLMEvent)?) {
        let worker = state.withLock { [continuation, elapsed] state -> Task<Void, Never>? in
            guard !state.ended else { return nil }
            state.ended = true
            state.summary.ms = milliseconds(elapsed())
            if let event { continuation.yield(event(state)) }
            continuation.finish()
            return state.worker
        }
        worker?.cancel()
    }
}

/// A call's connect, silence and total timers: cancellable sleeps on the call's clock. Starting one that runs
/// restarts it. Any of them running out calls `fire`.
private final class CallTimers: Sendable {
    enum Kind: Sendable {
        case connect
        case silence
        case total
    }

    private let clock: any Clock<Duration>
    private let fire: @Sendable () -> Void
    private let tasks = OSAllocatedUnfairLock<[Kind: Task<Void, Never>]>(initialState: [:])

    init(clock: any Clock<Duration>, fire: @escaping @Sendable () -> Void) {
        self.clock = clock
        self.fire = fire
    }

    func start(_ kind: Kind, after limit: Duration) {
        let task = Task { [clock, fire] in
            do {
                try await clock.sleep(for: limit)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            fire()
        }
        tasks.withLock { $0.updateValue(task, forKey: kind) }?.cancel()
    }

    func stop(_ kind: Kind) {
        tasks.withLock { $0.removeValue(forKey: kind) }?.cancel()
    }

    func stopAll() {
        let running = tasks.withLock { tasks -> [Task<Void, Never>] in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        for task in running { task.cancel() }
    }
}

/// The worker of one exchange and whether a timer cancelled it. A timer that fires once the whole body is in is too
/// late to count: the answer stands.
private final class WorkerHandle: Sendable {
    private struct State {
        var timedOut = false
        var finished = false
        var cancel: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var timedOut: Bool { state.withLock { $0.timedOut } }

    func attach(_ cancel: @escaping @Sendable () -> Void) {
        let timedOut = state.withLock { state -> Bool in
            state.cancel = cancel
            return state.timedOut
        }
        if timedOut { cancel() }
    }

    func finish() {
        state.withLock { $0.finished = true }
    }

    func timeOut() {
        let cancel = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.finished else { return nil }
            state.timedOut = true
            return state.cancel
        }
        cancel?()
    }
}

extension Clock where Duration == Swift.Duration {
    /// Time since the call, on the clock the timers use: tests on a manual clock get exact milliseconds. A member,
    /// so that calling it on `any Clock<Duration>` opens the existential.
    fileprivate func stopwatch() -> @Sendable () -> Duration {
        let start = now
        return { start.duration(to: self.now) }
    }
}

private func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
}

/// One model a server lists, and whether it reads images: nil when the entry says nothing of it.
public struct LLMModelListing: Sendable, Equatable {
    public var id: String
    public var vision: Bool?

    public init(id: String, vision: Bool? = nil) {
        self.id = id
        self.vision = vision
    }
}

/// `GET /models`, every field but the id optional: a server that names none of them is unknown, never "no".
private struct ModelsWire: Decodable {
    struct Modalities: Decodable {
        let input: [String]?
    }

    struct Architecture: Decodable {
        let inputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
        }
    }

    struct Capabilities: Decodable {
        struct Supported: Decodable {
            let supported: Bool?
        }

        let imageInput: Supported?

        enum CodingKeys: String, CodingKey {
            case imageInput = "image_input"
        }
    }

    struct Model: Decodable {
        let id: String
        let supportsVision: Bool?
        let modalities: Modalities?
        let architecture: Architecture?
        let capabilities: Capabilities?

        enum CodingKeys: String, CodingKey {
            case id, modalities, architecture, capabilities
            case supportsVision = "supports_vision"
        }

        /// The first field present, in that order.
        var vision: Bool? {
            supportsVision ?? modalities?.input.map { $0.contains("image") }
                ?? architecture?.inputModalities.map { $0.contains("image") } ?? capabilities?.imageInput?.supported
        }
    }

    let data: [Model]
}
