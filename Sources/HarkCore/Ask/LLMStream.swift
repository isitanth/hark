import Foundation

/// One message of a chat completion request.
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
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

    public init(
        model: String? = nil, ms: Int? = nil, finishReason: String? = nil, promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) {
        self.model = model
        self.ms = ms
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// Why an LLM call failed, in the terms the popup and Settings › Ask put into words.
public enum LLMFailure: Error, Sendable, Equatable {
    /// Connection refused, or no route: nothing listens at `endpoint` (`127.0.0.1:8002`).
    case notRunning(endpoint: String)
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

    /// The log's code for it.
    public var pipelineFailure: PipelineFailure {
        switch self {
        case .notRunning: .llmUnreachable
        case .keyRefused, .noKey: .llmUnauthorized
        case .noAnswer: .llmTimeout
        case .server(let status, _): .llmError(status: status)
        case .empty: .llmEmpty
        }
    }
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
