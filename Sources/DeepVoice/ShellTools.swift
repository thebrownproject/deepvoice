import Foundation
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "ShellTools")

private let maxOutput = 10_240
private let processTimeout: TimeInterval = 30

private let bashAllowlist: Set<String> = [
    "open", "ls", "cat", "head", "tail", "wc", "file", "which", "whoami",
    "date", "cal", "pwd", "echo", "mkdir", "cp", "mv", "rm", "touch",
    "grep", "find", "sort", "uniq", "diff", "tr", "cut", "pbcopy", "pbpaste",
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

private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var totalBytes = 0

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            totalBytes += data.count
            guard buffer.count < maxOutput else { return }
            let remaining = maxOutput - buffer.count
            buffer.append(data.prefix(remaining))
        }
    }

    func renderedString() -> String {
        let snapshot = lock.withLock { (buffer, totalBytes) }
        let rendered = String(decoding: snapshot.0, as: UTF8.self)
        guard snapshot.1 > snapshot.0.count else { return rendered }
        return rendered + "\n... truncated (\(snapshot.1) bytes total)"
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

    let stdoutHandle = stdoutPipe.fileHandleForReading
    let stderrHandle = stderrPipe.fileHandleForReading
    let stdoutAccumulator = OutputAccumulator()
    let stderrAccumulator = OutputAccumulator()

    stdoutHandle.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            return
        }
        stdoutAccumulator.append(data)
    }

    stderrHandle.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            return
        }
        stderrAccumulator.append(data)
    }

    try process.run()

    let result: String = try await withCheckedThrowingContinuation { continuation in
        let once = OnceFlag()

        func cleanup() {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
        }

        // Timeout: terminate process and resume with error
        DispatchQueue.global().asyncAfter(deadline: .now() + processTimeout) {
            if process.isRunning { process.terminate() }
            if once.claim() {
                cleanup()
                continuation.resume(throwing: ShellToolError.timeout)
            }
        }

        // Normal completion: read output and resume with result
        process.terminationHandler = { _ in
            cleanup()
            stdoutAccumulator.append(stdoutHandle.readDataToEndOfFile())
            stderrAccumulator.append(stderrHandle.readDataToEndOfFile())
            guard once.claim() else { return }

            let outStr = stdoutAccumulator.renderedString()
            let errStr = stderrAccumulator.renderedString()

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
