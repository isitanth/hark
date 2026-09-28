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

/// Streams one chat completion from an OpenAI-compatible endpoint, and lists its models. The key comes from the
/// secret store per call and goes only into the `Authorization` header; the timers run on the injected clock.
public actor LLMClient {
    /// The most of a non-200 body read for its message.
    static let errorBodyLimit = 64 * 1024
    /// The most of a `/models` body read.
    static let modelsBodyLimit = 1024 * 1024

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "llm")

    private let transport: any LLMTransport
    private let secrets: any SecretStore
    private let clock: any Clock<Duration>
    private let timeouts: LLMTimeouts

    public init(
        transport: any LLMTransport = URLSessionLLMTransport(), secrets: any SecretStore,
        clock: any Clock<Duration> = ContinuousClock(), timeouts: LLMTimeouts = .standard
    ) {
        self.transport = transport
        self.secrets = secrets
        self.clock = clock
        self.timeouts = timeouts
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
        let key: String?
        switch await resolveKey(for: profile) {
        case .success(let value): key = value
        case .failure(let failure): return .failure(failure)
        }
        var request = URLRequest(url: profile.baseURL.appending(path: "models"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let answer = await exchange(request, endpoint: profile.endpoint)
        switch answer {
        case .failure(let failure):
            return .failure(failure)
        case .success((401, _)):
            return .failure(.keyRefused)
        case .success((200, let body)):
            struct Wire: Decodable {
                struct Model: Decodable { let id: String }
                let data: [Model]
            }
            guard let wire = try? JSONDecoder().decode(Wire.self, from: body) else {
                return .failure(.server(status: 200, message: nil))
            }
            return .success(wire.data.map(\.id))
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

    static func chatRequest(
        _ messages: [ChatMessage], model: String, profile: ProviderProfile, key: String?
    ) -> URLRequest {
        var request = URLRequest(url: profile.baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": true,
            "max_tokens": profile.maxTokens,
            "temperature": profile.temperature,
        ]
        for (name, value) in profile.extra {
            switch value {
            case .bool(let flag): body[name] = flag
            case .int(let number): body[name] = number
            case .double(let number): body[name] = number
            case .string(let text): body[name] = text
            }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func failure(_ error: LLMTransportError, endpoint: String) -> LLMFailure {
        switch error {
        case .unreachable: .notRunning(endpoint: endpoint)
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
        let request = Self.chatRequest(messages, model: model, profile: profile, key: key)
        let call = StreamCall(continuation: continuation, elapsed: clock.stopwatch())
        // The timers start before the request, so a head that comes at once cannot stop a connect timer not yet set.
        let timers = CallTimers(clock: clock) { call.fail(.noAnswer) }
        timers.start(.total, after: timeouts.total)
        timers.start(.connect, after: timeouts.connect)
        let worker = Task { [transport, timeouts] in
            await Self.stream(
                request, transport: transport, endpoint: profile.endpoint, silence: timeouts.silence, call: call,
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
        _ request: URLRequest, transport: any LLMTransport, endpoint: String, silence: Duration, call: StreamCall,
        timers: CallTimers
    ) async {
        let response: LLMHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            if error == .cancelled && Task.isCancelled { return }
            return call.fail(failure(error, endpoint: endpoint))
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
            return call.fail(failure(error as? LLMTransportError ?? .other(code: 0), endpoint: endpoint))
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
    private func exchange(_ request: URLRequest, endpoint: String) async -> Result<(Int, Data), LLMFailure> {
        let handle = WorkerHandle()
        let timers = CallTimers(clock: clock) { handle.timeOut() }
        timers.start(.total, after: timeouts.probe)
        timers.start(.connect, after: timeouts.connect)
        let worker = Task { [transport] () -> Result<(Int, Data), LLMFailure> in
            let response: LLMHTTPResponse
            do {
                response = try await transport.send(request)
            } catch {
                return .failure(Self.failure(error as? LLMTransportError ?? .other(code: 0), endpoint: endpoint))
            }
            timers.stop(.connect)
            let body = await Self.read(response.body, limit: Self.modelsBodyLimit)
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
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(continuation: AsyncStream<LLMEvent>.Continuation, elapsed: @escaping @Sendable () -> Duration) {
        self.continuation = continuation
        self.elapsed = elapsed
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
        for item in data.map(ChatStreamItem.init(data:)) {
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

/// The worker of one exchange and whether a timer cancelled it.
private final class WorkerHandle: Sendable {
    private struct State {
        var timedOut = false
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

    func timeOut() {
        let cancel = state.withLock { state -> (@Sendable () -> Void)? in
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
