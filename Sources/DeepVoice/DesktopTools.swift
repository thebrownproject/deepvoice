import Foundation
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "DesktopTools")

private let defaultDisplayPrompt =
    "Describe the current screen concisely for DeepVoice. Focus on the active app, " +
    "the visible page or document, notable dialogs, and any UI the user is likely referring to."

enum DesktopTools {

    /// Replace placeholder handlers for frontmost_app_context and capture_display
    /// with real implementations backed by DesktopContextToolExecutor and OpenAI vision.
    @MainActor
    static func register(on registry: ToolRegistry, executor: DesktopContextToolExecutor) {
        registry.register(
            name: "frontmost_app_context",
            description: "Return structured context about the frontmost app and window.",
            parameters: [:],
            required: [],
            handler: { _ in
                let result = try await executor.execute(tool: "frontmost_app_context", args: [:])
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                return String(data: data, encoding: .utf8) ?? "{}"
            }
        )

        registry.register(
            name: "capture_display",
            description: "Capture the current display and return a concise vision summary plus metadata.",
            parameters: [
                "question": .object([
                    "type": .string("string"),
                    "description": .string("Optional question to focus the vision analysis"),
                ]),
            ],
            required: [],
            handler: { arguments in
                try await handleCaptureDisplay(arguments, executor: executor)
            }
        )
    }
}

// MARK: - capture_display

private func handleCaptureDisplay(_ arguments: String, executor: DesktopContextToolExecutor) async throws -> String {
    let question = parseQuestion(from: arguments)
    let prompt = question.isEmpty ? defaultDisplayPrompt : question

    let capture = try await executor.execute(tool: "capture_display", args: [:])

    guard let imageBase64 = capture["image_base64"] as? String, !imageBase64.isEmpty else {
        return errorJSON("capture_display", "missing image_base64 in capture payload")
    }

    let mimeType = capture["mime_type"] as? String ?? "image/jpeg"

    guard let apiKey = KeychainHelper.loadAPIKey(for: .openAIAPIKey) else {
        return errorJSON("capture_display", "OpenAI API key not configured")
    }

    let summary = try await callOpenAIChatCompletions(
        apiKey: apiKey,
        model: OpenAIModel.vision,
        messages: [
            [
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    [
                        "type": "image_url",
                        "image_url": [
                            "url": "data:\(mimeType);base64,\(imageBase64)",
                            "detail": "low",
                        ],
                    ],
                ],
            ] as [String: Any],
        ],
        maxTokens: 300
    )

    var payload: [String: Any] = [
        "summary": condenseForVoice(summary, maxChars: 500),
        "mime_type": mimeType,
    ]
    if let w = capture["width"] { payload["width"] = w }
    if let h = capture["height"] { payload["height"] = h }
    if let w = capture["original_width"] { payload["original_width"] = w }
    if let h = capture["original_height"] { payload["original_height"] = h }
    if let byteCount = capture["byte_count"] { payload["byte_count"] = byteCount }
    if let d = capture["display_id"] { payload["display_id"] = d }

    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - Helpers

private func parseQuestion(from arguments: String) -> String {
    guard let data = arguments.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let q = obj["question"] as? String else {
        return ""
    }
    return q.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func errorJSON(_ tool: String, _ message: String) -> String {
    log.error("Error in \(tool): \(message)")
    let escaped = message
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"error\":\"Error in \(tool): \(escaped)\"}"
}
