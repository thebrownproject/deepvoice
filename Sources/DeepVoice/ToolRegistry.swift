import Foundation
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "ToolRegistry")

typealias ToolHandler = (String) async throws -> String

final class ToolRegistry: @unchecked Sendable {
    private struct Registration {
        let definition: ToolDefinition
        let isDestructive: Bool
        let handler: ToolHandler
    }

    private let lock = NSLock()
    private var tools: [String: Registration] = [:]

    /// When true, destructive tools require user approval. Updated from ConfigStore.
    private var _confirmDestructive: Bool = true
    /// When true, destructive tools are blocked entirely.
    private var _safeMode: Bool = false

    @MainActor
    func setConfigStore(_ store: ConfigStore) {
        lock.withLock {
            _confirmDestructive = store.config.confirmDestructive
            _safeMode = store.config.safeMode
        }
    }

    func updateConfirmDestructive(_ value: Bool) {
        lock.withLock { _confirmDestructive = value }
    }

    func updateSafeMode(_ value: Bool) {
        lock.withLock { _safeMode = value }
    }

    func register(
        name: String,
        description: String,
        parameters: [String: JSONValue],
        required: [String],
        isDestructive: Bool = false,
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
            tools[name] = Registration(definition: def, isDestructive: isDestructive, handler: handler)
        }
        log.info("Registered tool: \(name)")
    }

    func toolDefinitions() -> [ToolDefinition] {
        lock.withLock { tools.values.map(\.definition) }
    }

    func execute(toolCall: ToolCall) async throws -> String {
        let (registration, safeMode) = lock.withLock {
            (tools[toolCall.function.name], _safeMode)
        }
        guard let registration else {
            let msg = "Unknown tool: \(toolCall.function.name)"
            log.error("\(msg)")
            return "Error: \(msg)"
        }
        if safeMode && registration.isDestructive {
            let msg = "Safe mode is on -- \(toolCall.function.name) is blocked"
            log.info("\(msg)")
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

    /// Check if a tool needs user approval. Destructive tools require approval
    /// only when `confirmDestructive` is enabled in the live config.
    func needsApproval(_ name: String) -> Bool {
        lock.withLock {
            guard let reg = tools[name], reg.isDestructive else { return false }
            return _confirmDestructive
        }
    }

    func registeredToolNames() -> [String] {
        lock.withLock { Array(tools.keys) }
    }
}

// MARK: - Default tool registration

extension ToolRegistry {
    /// Register all 8 tool schemas. frontmost_app_context and capture_display use
    /// placeholders here (overridden by DesktopTools.register); rest have real handlers.
    static func withDefaultTools() -> ToolRegistry {
        let registry = ToolRegistry()

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
            isDestructive: true,
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
            isDestructive: true,
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
            isDestructive: true,
            handler: handleFileWrite
        )

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
