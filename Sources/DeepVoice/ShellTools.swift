import Foundation
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "ShellTools")

private let maxOutput = 10_240
private let processTimeout: TimeInterval = 10

private let bashAllowlist: Set<String> = [
    "open", "ls", "cat", "head", "tail", "wc", "file", "which", "whoami",
    "date", "cal", "pwd", "echo", "mkdir", "cp", "mv", "rm", "touch",
    "grep", "find", "sort", "uniq", "diff", "tr", "cut", "pbcopy", "pbpaste",
    "ddgr", "curl", "jq", "sw_vers", "defaults", "pmset", "df", "du",
]

private let dangerousPatterns = [
    "rm -rf /", "rm -rf ~", "mkfs", "dd if=", ":()", "> /dev/sd",
]

private let shellMetacharacters = CharacterSet(charactersIn: ";|&`$(){}\\!<>\n\r")

enum ShellToolError: Error, LocalizedError {
    case missingArgument(String)
    case timeout
    case processError(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let arg): return "Missing required argument: \(arg)"
        case .timeout: return "Command timed out after \(Int(processTimeout))s"
        case .processError(let msg): return msg
        }
    }
}

private struct ArgsParser {
    let json: [String: Any]

    init(_ raw: String) throws {
        guard let data = raw.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShellToolError.missingArgument("valid JSON")
        }
        json = obj
    }

    func string(_ key: String) throws -> String {
        guard let value = json[key] as? String, !value.isEmpty else {
            throw ShellToolError.missingArgument(key)
        }
        return value
    }
}

private func isDangerous(_ command: String) -> Bool {
    let trimmed = command.trimmingCharacters(in: .whitespaces)
    return dangerousPatterns.contains { trimmed.contains($0) }
}

private func truncateOutput(_ output: String) -> String {
    guard output.count > maxOutput else { return output }
    return String(output.prefix(maxOutput)) + "\n... truncated (\(output.count) chars total)"
}

/// Tracks whether a continuation has been resumed to prevent double-resume crashes.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Returns true exactly once; all subsequent calls return false.
    func claim() -> Bool {
        lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
    }
}

private func runProcess(
    executable: String,
    arguments: [String]
) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    let result: String = try await withCheckedThrowingContinuation { continuation in
        let once = OnceFlag()

        // Timeout: terminate process and resume with error
        DispatchQueue.global().asyncAfter(deadline: .now() + processTimeout) {
            if process.isRunning { process.terminate() }
            if once.claim() {
                continuation.resume(throwing: ShellToolError.timeout)
            }
        }

        // Normal completion: read output and resume with result
        process.terminationHandler = { _ in
            let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            guard once.claim() else { return }

            let outStr = String(data: out, encoding: .utf8) ?? ""
            let errStr = String(data: err, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 && !errStr.isEmpty {
                let msg = errStr.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: "Error: \(msg)")
            } else {
                let combined = (outStr + errStr).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: combined.isEmpty ? "(no output)" : combined)
            }
        }
    }

    return truncateOutput(result)
}

func safeBashHandler(_ arguments: String) async throws -> String {
    let args = try ArgsParser(arguments)
    let command = try args.string("command")

    if isDangerous(command) {
        log.warning("Blocked dangerous command: \(command)")
        return "Error in safe_bash: dangerous command pattern detected"
    }

    // Reject shell metacharacters to prevent injection via chaining
    if command.unicodeScalars.contains(where: { shellMetacharacters.contains($0) }) {
        log.warning("Blocked command with shell metacharacters: \(command)")
        return "Error in safe_bash: shell metacharacters (;|&`$(){}\\!<>) are not allowed"
    }

    let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
    guard let baseCmd = parts.first else {
        return "Error in safe_bash: command is empty"
    }
    let cmdName = URL(fileURLWithPath: baseCmd).lastPathComponent
    guard bashAllowlist.contains(cmdName) else {
        log.warning("Command not in allowlist: \(cmdName)")
        return "Error in safe_bash: '\(cmdName)' not in bash allowlist"
    }

    log.info("Executing: \(command)")
    do {
        return try await runProcess(executable: "/bin/bash", arguments: ["-c", command])
    } catch ShellToolError.timeout {
        return "Error in safe_bash: command timed out after \(Int(processTimeout))s"
    } catch {
        return "Error in safe_bash: \(error.localizedDescription)"
    }
}

func applescriptHandler(_ arguments: String) async throws -> String {
    let args = try ArgsParser(arguments)
    let script = try args.string("script")

    log.info("Executing AppleScript (\(script.prefix(80))...)")
    do {
        return try await runProcess(executable: "/usr/bin/osascript", arguments: ["-e", script])
    } catch ShellToolError.timeout {
        return "Error in applescript: script timed out after \(Int(processTimeout))s"
    } catch {
        return "Error in applescript: \(error.localizedDescription)"
    }
}
