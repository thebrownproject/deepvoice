import SwiftUI

struct DevConsoleActions {
    var onTalkToggle: () -> Void = {}
    var onInterrupt: () -> Void = {}
    var onApprove: (_ callId: String, _ always: Bool) -> Void = { _, _ in }
    var onReject: (_ callId: String, _ always: Bool) -> Void = { _, _ in }
    var onClearLog: () -> Void = {}
}

struct DevConsoleView: View {
    var state: DevConsoleState
    var actions: DevConsoleActions

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            consoleLog
            Divider()
            if !state.pendingApprovals.isEmpty {
                approvalSection
                Divider()
            }
            controlBar
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            statusCapsule(appStateLabel, color: appStateColor)
            statusCapsule(connectionLabel, color: connectionColor)
            statusCapsule(state.isCapturing ? "Mic: on" : "Mic: off",
                          color: state.isCapturing ? .blue : .gray)
            if state.isPlaying {
                statusCapsule("Playing", color: .green)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func statusCapsule(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.85), in: Capsule())
    }

    private var appStateLabel: String {
        "State: \(state.appState.rawValue)"
    }

    private var appStateColor: Color {
        switch state.appState {
        case .idle: .green
        case .listening: .blue
        case .thinking: .orange
        case .speaking: .green
        case .error: .red
        }
    }

    private var connectionLabel: String {
        switch state.connectionState {
        case .disconnected: "API: disconnected"
        case .connecting: "API: connecting"
        case .connected: "API: connected"
        }
    }

    private var connectionColor: Color {
        switch state.connectionState {
        case .disconnected: .red
        case .connecting: .yellow
        case .connected: .green
        }
    }

    private var consoleLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(state.logEntries) { entry in
                        logEntryRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: state.logEntries.count) { _, _ in
                if let last = state.logEntries.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func logEntryRow(_ entry: ConsoleLogEntry) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("[\(Self.timeFormatter.string(from: entry.timestamp))] ")
                .foregroundStyle(.secondary)
            Text(entry.message)
                .foregroundStyle(logColor(for: entry.level))
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }

    private func logColor(for level: LogLevel) -> Color {
        switch level {
        case .info: .primary
        case .warning: .orange
        case .error: .red
        case .debug: .secondary
        }
    }

    private var approvalSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.pendingApprovals) { approval in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("APPROVAL: \(approval.toolName)")
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundStyle(.orange)
                        Text(approval.argsDescription)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Approve") { actions.onApprove(approval.id, false) }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)
                    Button("Reject") { actions.onReject(approval.id, false) }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.small)
                    Button("Always") { actions.onApprove(approval.id, true) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button(action: actions.onTalkToggle) {
                Text(talkButtonLabel)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Interrupt", action: actions.onInterrupt)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(state.appState == .idle && !state.isCapturing && !state.isPlaying)

            Button("Clear", action: actions.onClearLog)
                .buttonStyle(.bordered)
                .controlSize(.regular)

            Button("Copy", action: copyLog)
                .buttonStyle(.bordered)
                .controlSize(.regular)

            Spacer()

            Button(action: openSettings) {
                Image(systemName: "gear")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var talkButtonLabel: String {
        switch state.appState {
        case .listening: "Listening..."
        default: "Talk (Opt+S)"
        }
    }

    private func copyLog() {
        let text = state.logEntries.map { entry in
            "[\(Self.timeFormatter.string(from: entry.timestamp))] \(entry.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
