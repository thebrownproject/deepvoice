import Foundation
import Observation

/// Replaces WebSocketConnectionState for the pure-Swift spike.
/// Tracks connection status to external API services instead of local Python backend.
enum ConnectionState: String {
    case disconnected
    case connecting
    case connected
}

@Observable @MainActor
final class DevConsoleState {
    var appState: AppState = .idle
    var connectionState: ConnectionState = .disconnected
    var isCapturing = false
    var isPlaying = false

    var logEntries: [ConsoleLogEntry] = []
    var transcriptEntries: [TranscriptEntry] = []
    var pendingApprovals: [PendingApproval] = []

    private static let maxLogEntries = 500

    func log(_ message: String, level: LogLevel = .info) {
        logEntries.append(ConsoleLogEntry(timestamp: Date(), level: level, message: message))
        if logEntries.count > Self.maxLogEntries {
            logEntries.removeFirst(logEntries.count - Self.maxLogEntries)
        }
    }

    private static let maxTranscriptEntries = 50

    func addTranscript(role: String, text: String, isFinal: Bool) {
        TranscriptEntry.merge(into: &transcriptEntries, role: role, text: text, isFinal: isFinal, maxEntries: Self.maxTranscriptEntries)
    }

    func addApproval(callId: String, toolName: String, argsDescription: String) {
        let approval = PendingApproval(
            id: callId,
            toolName: toolName,
            argsDescription: argsDescription,
            timestamp: Date()
        )
        pendingApprovals.append(approval)
    }

    func removeApproval(callId: String) {
        pendingApprovals.removeAll { $0.id == callId }
    }

    func clearLog() {
        logEntries.removeAll()
    }
}

struct ConsoleLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String
}

enum LogLevel: String {
    case info, warning, error, debug
}

struct PendingApproval: Identifiable {
    let id: String
    let toolName: String
    let argsDescription: String
    let timestamp: Date
}
