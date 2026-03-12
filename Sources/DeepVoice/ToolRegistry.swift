import Foundation
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "ToolRegistry")

typealias ToolHandler = (String) async throws -> String

final class ToolRegistry: @unchecked Sendable {
    private struct Registration {
        let definition: ToolDefinition
        let needsApproval: Bool
        let handler: ToolHandler
    }

    private let lock = NSLock()
    private var tools: [String: Registration] = [:]

    func register(
        name: String,
        description: String,
        parameters: [String: JSONValue],
        required: [String],
        needsApproval: Bool = false,
        handler: @escaping ToolHandler
    ) {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(parameters),
            "required": .array(required.map { .string($0) }),
        ])
        let def = ToolDefinition(
            type: "function",
            function: FunctionDefinition(
                name: name,
                description: description,
                parameters: schema
            )
        )
        lock.withLock {
            tools[name] = Registration(definition: def, needsApproval: needsApproval, handler: handler)
        }
        log.info("Registered tool: \(name)")
    }

    func toolDefinitions() -> [ToolDefinition] {
        lock.withLock { tools.values.map(\.definition) }
    }

    func execute(toolCall: ToolCall) async throws -> String {
        let registration = lock.withLock { tools[toolCall.function.name] }
        guard let registration else {
            let msg = "Unknown tool: \(toolCall.function.name)"
            log.error("\(msg)")
            return "Error: \(msg)"
        }
        do {
            return try await registration.handler(toolCall.function.arguments)
        } catch {
            let msg = "Error in \(toolCall.function.name): \(error.localizedDescription)"
            log.error("\(msg)")
            return msg
        }
    }

    func needsApproval(_ name: String) -> Bool {
        lock.withLock { tools[name]?.needsApproval ?? false }
    }

    func registeredToolNames() -> [String] {
        lock.withLock { Array(tools.keys) }
    }
}

// MARK: - Default tool registration

extension ToolRegistry {
    /// Register the default tool schemas. frontmost_app_context and capture_display use
    /// placeholders here (overridden by DesktopTools.register). Safe mode hides file_write.
    static func withDefaultTools(config: DeepVoiceConfig) -> ToolRegistry {
        let registry = ToolRegistry()
        let guardedApproval = config.confirmDestructive || config.safeMode

        registry.register(
            name: "safe_bash",
            description: "Execute a shell command with safety controls and timeout.",
            parameters: [
                "command": .object([
                    "type": .string("string"),
                    "description": .string("The shell command to execute"),
                ]),
            ],
            required: ["command"],
            needsApproval: guardedApproval,
            handler: safeBashHandler
        )

        registry.register(
            name: "applescript",
            description: "Execute AppleScript to control macOS applications. Use for Calendar, Reminders, Finder, Safari, Music, Spotify, Notes, Messages, Mail, System Events, and other scriptable apps.",
            parameters: [
                "script": .object([
                    "type": .string("string"),
                    "description": .string("The AppleScript source to execute"),
                ]),
            ],
            required: ["script"],
            needsApproval: guardedApproval,
            handler: applescriptHandler
        )

        registry.register(
            name: "file_read",
            description: "Read a file and return its contents.",
            parameters: [
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to the file to read"),
                ]),
            ],
            required: ["path"],
            handler: handleFileRead
        )

        if !config.safeMode {
            registry.register(
                name: "file_write",
                description: "Write content to a file, creating parent directories as needed.",
                parameters: [
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Path to the file to write"),
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("Content to write to the file"),
                    ]),
                ],
                required: ["path", "content"],
                needsApproval: config.confirmDestructive,
                handler: handleFileWrite
            )
        }

        registry.register(
            name: "frontmost_app_context",
            description: "Return structured context about the frontmost app and window.",
            parameters: [:],
            required: [],
            handler: placeholder
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
            handler: placeholder
        )

        registry.register(
            name: "reason_deeply",
            description: "Delegate complex reasoning to a specialist. Use for multi-step analysis, math, code review, planning, or comparisons that need deeper thought. Returns a concise answer for voice delivery.",
            parameters: [
                "task": .object([
                    "type": .string("string"),
                    "description": .string("The reasoning task to delegate"),
                ]),
            ],
            required: ["task"],
            handler: reasonDeeplyHandler
        )

        registry.register(
            name: "web_search",
            description: "Search the web and return relevant results with titles, snippets, and URLs.",
            parameters: [
                "query": .object([
                    "type": .string("string"),
                    "description": .string("The search query"),
                ]),
            ],
            required: ["query"],
            handler: webSearchHandler
        )

        return registry
    }
}

private func placeholder(_ arguments: String) async throws -> String {
    "Tool not yet implemented"
}
