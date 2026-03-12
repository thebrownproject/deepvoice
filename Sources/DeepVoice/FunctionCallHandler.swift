import Foundation
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "FunctionCallHandler")

@MainActor
protocol FunctionCallApprovalDelegate: AnyObject {
    func functionCallNeedsApproval(id: String, name: String, args: String) async -> Bool
}

enum FunctionCallError: LocalizedError {
    case approvalTimeout(name: String)
    case approvalRejected(name: String)
    case unknownTool(name: String)

    var errorDescription: String? {
        switch self {
        case .approvalTimeout(let name): "Approval timed out for \(name)"
        case .approvalRejected(let name): "User rejected \(name)"
        case .unknownTool(let name): "Unknown tool: \(name)"
        }
    }
}

final class FunctionCallHandler: @unchecked Sendable {
    private let toolRegistry: ToolRegistry
    private let agentClient: DeepgramAgentClient
    private let approvalTimeout: TimeInterval

    weak var approvalDelegate: FunctionCallApprovalDelegate?

    init(
        toolRegistry: ToolRegistry,
        agentClient: DeepgramAgentClient,
        approvalTimeout: TimeInterval = 60
    ) {
        self.toolRegistry = toolRegistry
        self.agentClient = agentClient
        self.approvalTimeout = approvalTimeout
    }

    /// Handle an incoming function call from the Voice Agent API.
    /// Checks approval, executes, and sends the response back. Errors are sent
    /// as the response content so the LLM can see them.
    func handle(id: String, name: String, arguments: String) {
        Task { [weak self] in
            guard let self else { return }
            let output = await self.process(id: id, name: name, arguments: arguments)
            self.agentClient.sendFunctionCallResponse(id: id, name: name, output: output)
        }
    }

    /// Common LLM hallucinated tool names mapped to real tool names.
    private static let toolAliases: [String: String] = [
        "bash": "safe_bash",
        "shell": "safe_bash",
        "run_bash": "safe_bash",
        "execute": "safe_bash",
        "read_file": "file_read",
        "write_file": "file_write",
    ]

    private func process(id: String, name: String, arguments: String) async -> String {
        let resolvedName = Self.toolAliases[name] ?? name
        if resolvedName != name {
            log.info("Aliased tool \(name) -> \(resolvedName)")
        }
        log.info("Function call: \(resolvedName) (id: \(id))")

        // Approval gate
        if toolRegistry.needsApproval(resolvedName) {
            do {
                let approved = try await requestApproval(id: id, name: resolvedName, arguments: arguments)
                if !approved {
                    log.info("User rejected \(resolvedName)")
                    return "Error: \(FunctionCallError.approvalRejected(name: resolvedName).localizedDescription)"
                }
            } catch {
                log.warning("Approval failed for \(resolvedName): \(error.localizedDescription)")
                return "Error: \(error.localizedDescription)"
            }
        }

        // Build ToolCall from Voice Agent format and execute
        let toolCall = ToolCall(
            id: id,
            type: "function",
            function: FunctionCall(name: resolvedName, arguments: arguments)
        )

        do {
            let result = try await toolRegistry.execute(toolCall: toolCall)
            log.info("Tool \(name) completed (\(result.count) chars)")
            return result
        } catch {
            let msg = "Error executing \(name): \(error.localizedDescription)"
            log.error("\(msg)")
            return msg
        }
    }

    /// Request approval from the delegate with a timeout.
    private func requestApproval(id: String, name: String, arguments: String) async throws -> Bool {
        guard let delegate = approvalDelegate else {
            log.warning("No approval delegate set, auto-rejecting \(name)")
            throw FunctionCallError.approvalRejected(name: name)
        }

        log.info("Requesting approval for \(name)")

        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                await delegate.functionCallNeedsApproval(id: id, name: name, args: arguments)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.approvalTimeout * 1_000_000_000))
                throw FunctionCallError.approvalTimeout(name: name)
            }

            // First result wins: either user responds or timeout fires
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
