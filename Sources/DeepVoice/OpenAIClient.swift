import Foundation
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "OpenAIClient")

enum OpenAIModel {
    static let delegation = "gpt-5-mini-2025-08-07"
    static let vision = "gpt-4o-mini"
    static let webSearch = "gpt-4o-mini"
}

enum OpenAIError: LocalizedError {
    case httpError(statusCode: Int, body: String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            "OpenAI API returned \(code): \(String(body.prefix(200)))"
        case .unexpectedResponse(let api):
            "Unexpected response format from OpenAI \(api) API"
        }
    }
}

private let defaultTimeout: TimeInterval = 30

/// Call the OpenAI Chat Completions API and return the first message content.
func callOpenAIChatCompletions(
    apiKey: String,
    model: String,
    messages: [[String: Any]],
    maxTokens: Int? = nil,
    timeout: TimeInterval = defaultTimeout
) async throws -> String {
    let url = URL(string: "https://api.openai.com/v1/chat/completions")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = timeout

    var body: [String: Any] = [
        "model": model,
        "messages": messages,
    ]
    if let maxTokens {
        body["max_tokens"] = maxTokens
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)

    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        let respBody = String(data: data, encoding: .utf8) ?? "(no body)"
        throw OpenAIError.httpError(statusCode: http.statusCode, body: respBody)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = json["choices"] as? [[String: Any]],
          let first = choices.first,
          let message = first["message"] as? [String: Any],
          let content = message["content"] as? String else {
        throw OpenAIError.unexpectedResponse("chat completions")
    }

    return content
}
