import Foundation

enum AppState: String, CaseIterable {
    case idle
    case listening
    case thinking
    case speaking
    case error
}

struct ToolCall: Codable, Sendable {
    let id: String
    let type: String
    let function: FunctionCall
}

struct FunctionCall: Codable, Sendable {
    let name: String
    let arguments: String
}

struct ToolDefinition: Sendable {
    let type: String
    let function: FunctionDefinition
}

struct FunctionDefinition: Sendable {
    let name: String
    let description: String
    let parameters: JSONValue
}

enum JSONValue: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }
}

extension ToolDefinition: Encodable {
    enum CodingKeys: String, CodingKey { case type, function }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(function, forKey: .function)
    }
}

extension FunctionDefinition: Encodable {
    enum CodingKeys: String, CodingKey { case name, description, parameters }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(parameters, forKey: .parameters)
    }
}

/// Strip markdown formatting and truncate to a voice-friendly length.
func condenseForVoice(_ text: String, maxChars: Int) -> String {
    let out = text
        .replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression)
        .replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        .replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
        .replacingOccurrences(of: "^[\\s]*[-*]\\s+", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\*{1,2}([^*]+)\\*{1,2}", with: "$1", options: .regularExpression)
        .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        .replacingOccurrences(of: "\\n{2,}", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard out.count > maxChars else { return out }

    let truncated = String(out.prefix(maxChars))
    if let range = truncated.range(of: ". ", options: .backwards) {
        return String(truncated[truncated.startIndex...range.lowerBound]) + "."
    }
    return truncated + "..."
}
