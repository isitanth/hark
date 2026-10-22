import Foundation

/// One message of a chat completion request.
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    public var role: Role
    /// Text, and from M11 the image of a framed region.
    public var parts: [ContentPart]

    /// A message of text alone, as every message was before M11.
    public init(role: Role, content: String) {
        self.role = role
        self.parts = [.text(content)]
    }

    public init(role: Role, parts: [ContentPart]) {
        self.role = role
        self.parts = parts
    }

    /// The text parts, joined: the whole message when it holds no image.
    public var content: String {
        parts.compactMap {
            guard case .text(let text) = $0 else { return nil }
            return text
        }.joined()
    }

    /// Whether any part is an image.
    public var hasImage: Bool {
        parts.contains {
            guard case .image = $0 else { return false }
            return true
        }
    }
}

/// What one streamed chat completion produces, in order: any number of `text`, then exactly one `finished` or
/// `failed`, then the stream ends. Cancelling the task that iterates it cancels the request.
public enum LLMEvent: Sendable, Equatable {
    /// A piece of the answer, `delta.content` as the server sent it. Never empty.
    case text(String)
    case finished(LLMCallSummary)
    /// The text received so far stays with the consumer: a timeout after some words is still `llmTimeout`.
    case failed(LLMFailure, LLMCallSummary)
}

/// What the log keeps of one LLM call, and what the popup shows of it.
public struct LLMCallSummary: Sendable, Equatable {
    /// The id the server's chunks named. Nil when no chunk arrived.
    public var model: String?
    /// From the request to the last token, or to the failure. Nil when no request was sent (no key in the Keychain).
    public var ms: Int?
    /// `stop` or `length`, from the finish chunk.
    public var finishReason: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    /// The profile and model turn 1's request went to, filled by the engine: what a first follow-up pins. Nil when no
    /// request was resolved, and on a follow-up, which keeps its thread's pin.
    public var pin: ProfilePin?

    public init(
        model: String? = nil, ms: Int? = nil, finishReason: String? = nil, promptTokens: Int? = nil,
        completionTokens: Int? = nil, pin: ProfilePin? = nil
    ) {
        self.model = model
        self.ms = ms
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.pin = pin
    }
}

/// Why an LLM call failed, in the terms the popup and Settings › Ask put into words.
public enum LLMFailure: Error, Sendable, Equatable {
    /// Connection refused, or no route: nothing listens at `endpoint` (`127.0.0.1:8002`) on this Mac.
    case notRunning(endpoint: String)
    /// The same for a server elsewhere (`api.anthropic.com`): no network, no route or a failed TLS handshake. There is
    /// nothing to start.
    case unreachable(host: String)
    /// 401: the server refused the key.
    case keyRefused
    /// The profile takes a key and the Keychain has none for it. No request was sent.
    case noKey
    /// No response head within the connect timeout, stream silence before the first word, or past the total limit.
    case noAnswer
    /// Any other status, with the body's `error.message`; or an error chunk inside the stream, with no status.
    case server(status: Int?, message: String?)
    /// The stream finished without a word of content.
    case empty
    /// Claude's safety filters declined the request, and no fallback model answered it.
    case refused
    /// The model cannot read the image the ask carried: the server said so, or it was known before sending. `model`
    /// is the id asked for, when known.
    case noVision(model: String?, reason: VisionRefusal)
    /// A follow-up, and the active profile is no longer the one turn 1 went to (its name or its signature changed in
    /// Settings): nothing was sent (M12).
    case profileChanged
    /// A follow-up whose conversation names a framed turn the controller holds no image for: nothing was sent, so the
    /// model is never told about an image that is not there.
    case frameMissing

    /// The log's code for it.
    public var pipelineFailure: PipelineFailure {
        switch self {
        case .notRunning, .unreachable: .llmUnreachable
        case .keyRefused, .noKey: .llmUnauthorized
        case .noAnswer: .llmTimeout
        case .server(let status, _): .llmError(status: status)
        case .refused: .llmError(status: nil)
        case .empty: .llmEmpty
        case .noVision: .llmNoVision
        case .profileChanged: .llmProfileChanged
        case .frameMissing: .regionFailed
        }
    }
}

/// How Hark knows a model cannot read an image: each has its own words in the panel.
public enum VisionRefusal: Sendable, Equatable {
    /// The server refused the image in words Hark recognizes: the model has no vision.
    case noVision
    /// MTPLX in AR mode, which takes no image: the server must restart in MTP mode.
    case needsMTPMode
    /// The models list, or an earlier refusal, said so: nothing was sent.
    case knownBeforeSending
}

/// The client's three limits, measured in M8.0: a live server accepts in under 5 ms and sends its head at once, even
/// before a long prefill, and a 3,000-token selection waits about 11 s for its first word.
public struct LLMTimeouts: Sendable, Equatable {
    /// From the request to the response head.
    public var connect: Duration
    /// Before the first word, the longest gap between two stream lines. A `:` heartbeat or an empty progress chunk
    /// counts as a line.
    public var silence: Duration
    /// From the request to the end of the stream.
    public var total: Duration
    /// The whole of `GET /models` for Settings' check and the pre-flight: a server that is up answers it at once.
    public var probe: Duration

    public init(connect: Duration, silence: Duration, total: Duration, probe: Duration = .seconds(5)) {
        self.connect = connect
        self.silence = silence
        self.total = total
        self.probe = probe
    }

    public static let standard = LLMTimeouts(connect: .seconds(2), silence: .seconds(15), total: .seconds(60))

    /// Not measured: a cold DNS, TCP and TLS handshake across the internet, then Claude thinking or a declined request
    /// replayed on the fallback model before the first word. Measured 2026-10-12 from this Mac, the head of a 401 from
    /// api.anthropic.com came in 0.2 s, once in 1.2 s after a lost SYN.
    public static let remote = LLMTimeouts(
        connect: .seconds(10), silence: .seconds(45), total: .seconds(120), probe: .seconds(10))
}

/// The HTTP side of the client, a seam so tests script the server. The real one lives in `LLMClient.swift`, the one
/// file of the Ask engine allowed to open a connection.
public protocol LLMTransport: Sendable {
    /// Sends `request` and returns once the response head is in. The body arrives as chunks; the stream throws a
    /// `LLMTransportError` when the connection fails and ends with the body. Ending the iteration cancels the request.
    func send(_ request: URLRequest) async throws(LLMTransportError) -> LLMHTTPResponse
}

public struct LLMHTTPResponse: Sendable {
    public let status: Int
    public let body: AsyncThrowingStream<Data, any Error>

    public init(status: Int, body: AsyncThrowingStream<Data, any Error>) {
        self.status = status
        self.body = body
    }
}

public enum LLMTransportError: Error, Sendable, Equatable {
    /// Refused, no route, host not found: nothing answers at that address.
    case unreachable
    /// The transport's own timer ran out.
    case timedOut
    case cancelled
    /// Anything else, with the `URLError` code.
    case other(code: Int)
}
