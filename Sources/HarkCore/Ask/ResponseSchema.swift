import Foundation

/// A JSON schema the server is asked to enforce on a reply (M13): OpenAI's `response_format: json_schema`, Claude's
/// `output_config.format`. `json` is the schema object, as it is sent.
public struct ResponseSchema: Sendable, Equatable {
    public let name: String
    public let json: String

    public init(name: String, json: String) {
        self.name = name
        self.json = json
    }
}
