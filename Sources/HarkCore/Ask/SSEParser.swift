import Foundation

/// Server-sent events, fed as bytes in whatever pieces the network hands over. A line cut between two pieces waits
/// for the rest. Lines end with LF, CRLF or CR; a blank line dispatches the event's `data:` lines, joined by LF.
/// Comments (`: keep-alive`) and the other fields (`event`, `id`, `retry`) carry nothing this client reads.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var data: [String] = []
    private var afterCR = false

    public init() {}

    /// The events completed by `bytes`, as their data.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [String] {
        var events: [String] = []
        for byte in bytes {
            if afterCR {
                afterCR = false
                if byte == UInt8(ascii: "\n") { continue }
            }
            switch byte {
            case UInt8(ascii: "\n"):
                endLine(into: &events)
            case UInt8(ascii: "\r"):
                afterCR = true
                endLine(into: &events)
            default:
                line.append(byte)
            }
        }
        return events
    }

    /// The end of the stream: a last line without its newline counts, and data not yet dispatched is dispatched.
    public mutating func finish() -> [String] {
        var events: [String] = []
        if !line.isEmpty { endLine(into: &events) }
        dispatch(into: &events)
        return events
    }

    private mutating func endLine(into events: inout [String]) {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else { return dispatch(into: &events) }
        guard line.first != UInt8(ascii: ":") else { return }
        let text = String(decoding: line, as: UTF8.self)
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        if field == "data" { data.append(String(value)) }
    }

    private mutating func dispatch(into events: inout [String]) {
        guard !data.isEmpty else { return }
        events.append(data.joined(separator: "\n"))
        data.removeAll()
    }
}

/// One `data:` payload of an OpenAI-compatible chat completion stream, read for what the ask needs: `delta.content`,
/// the finish reason, the usage and the model id. `reasoning_content`, MTPLX's `mtplx_progress` and `mtplx_stats`,
/// and every other field are skipped.
public enum ChatStreamItem: Sendable, Equatable {
    case chunk(ChatStreamChunk)
    /// `{"error": …}` inside the stream, with its message when it has one.
    case error(message: String?)
    /// `[DONE]`.
    case done
    /// Not JSON, or not a chunk. Skipped.
    case unreadable

    public init(data: String) {
        if data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            self = .done
            return
        }
        guard let wire = try? JSONDecoder().decode(WireChunk.self, from: Data(data.utf8)) else {
            self = .unreadable
            return
        }
        if let error = wire.error {
            self = .error(message: error.message)
            return
        }
        let choice = wire.choices?.first
        let content = choice?.delta?.content
        self = .chunk(
            ChatStreamChunk(
                model: wire.model, content: content?.isEmpty == false ? content : nil,
                finishReason: choice?.finishReason, promptTokens: wire.usage?.promptTokens,
                completionTokens: wire.usage?.completionTokens))
    }
}

public struct ChatStreamChunk: Sendable, Equatable {
    public var model: String?
    /// Nil when the delta had none, or an empty one: a role chunk, a progress chunk, reasoning.
    public var content: String?
    public var finishReason: String?
    /// MTPLX sends the usage in the finish chunk; OpenAI in a last chunk with no choices.
    public var promptTokens: Int?
    public var completionTokens: Int?

    public init(
        model: String? = nil, content: String? = nil, finishReason: String? = nil, promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) {
        self.model = model
        self.content = content
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

private struct WireChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    let model: String?
    let choices: [Choice]?
    let usage: Usage?
    let error: WireError?
}

/// The error chunk and the error body share this shape: `{"error": {"message": …}}`, or a bare string.
struct WireError: Decodable {
    let message: String?

    init(from decoder: any Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            message = text
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
    }

    private enum CodingKeys: String, CodingKey {
        case message
    }
}

/// The body of a response that is not 200: MTPLX's 401 is `{"error":{"message":"missing or invalid API key",…}}`.
public enum LLMErrorBody {
    /// `error.message`, when the body has one.
    public static func message(in body: Data) -> String? {
        struct Wire: Decodable {
            let error: WireError?
        }
        return (try? JSONDecoder().decode(Wire.self, from: body))?.error?.message
    }
}
