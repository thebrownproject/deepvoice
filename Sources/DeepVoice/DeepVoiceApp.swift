import AppKit
import SwiftUI

@main
struct DeepVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("DeepVoice Console") {
            DevConsoleView(state: appDelegate.consoleState, actions: appDelegate.consoleActions)
        }
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let consoleState = DevConsoleState()
    let hotkeyManager = HotkeyManager()
    let audioManager = AudioManager()
    let agentClient = DeepgramAgentClient()
    let desktopContextToolExecutor = DesktopContextToolExecutor()
    private(set) var toolRegistry: ToolRegistry?
    private(set) var functionCallHandler: FunctionCallHandler?
    private var config: DeepVoiceConfig = .defaults
    private var deepgramAPIKey: String?
    private var openRouterAPIKey: String?

    private var pendingContinuations: [String: CheckedContinuation<Bool, Never>] = [:]
    private var alwaysApprovedTools: Set<String> = []

    lazy var consoleActions: DevConsoleActions = DevConsoleActions(
        onTalkToggle: { [weak self] in self?.toggleListening() },
        onInterrupt: { [weak self] in self?.interruptSession() },
        onApprove: { [weak self] callId, always in self?.resolveApproval(callId: callId, approved: true, always: always) },
        onReject: { [weak self] callId, always in self?.resolveApproval(callId: callId, approved: false, always: always) },
        onClearLog: { [weak self] in self?.consoleState.clearLog() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyManager.delegate = self
        agentClient.delegate = self
        consoleState.audioManager = audioManager

        Task {
            let granted = await audioManager.requestPermission()
            consoleState.log("Mic permission: \(granted ? "granted" : "denied")",
                            level: granted ? .info : .warning)
        }

        DeepVoiceConfig.bootstrapStorage()

        if let loaded = try? DeepVoiceConfig.load() {
            config = loaded
            consoleState.log("Config loaded (llm: \(config.llmProvider)/\(config.llmModel))")
        }

        for account in KeychainAccount.allCases {
            if KeychainHelper.loadAPIKey(for: account) != nil {
                consoleState.log("\(account.rawValue): configured")
            } else {
                consoleState.log("\(account.rawValue): not set", level: .warning)
            }
        }

        deepgramAPIKey = KeychainHelper.loadAPIKey(for: .deepgramAPIKey)
        openRouterAPIKey = KeychainHelper.loadAPIKey(for: .openRouterAPIKey)

        let registry = ToolRegistry.withDefaultTools(confirmDestructive: config.confirmDestructive)
        DesktopTools.register(on: registry, executor: desktopContextToolExecutor)
        toolRegistry = registry

        let handler = FunctionCallHandler(
            toolRegistry: registry,
            agentClient: agentClient
        )
        handler.approvalDelegate = self
        functionCallHandler = handler

        consoleState.log("DeepVoice launched (Voice Agent mode)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentClient.disconnect()
        audioManager.stopCapture()
    }

    // MARK: - Session control

    private func toggleListening() {
        switch consoleState.appState {
        case .idle, .error:
            startSession()
        case .listening:
            stopSession()
        case .thinking, .speaking:
            interruptSession()
        }
    }

    private func startSession() {
        guard let deepgramKey = deepgramAPIKey else {
            consoleState.log("Cannot start -- Deepgram API key not set", level: .error)
            return
        }

        consoleState.connectionState = .connecting
        consoleState.log("Connecting to Voice Agent...")

        agentClient.connect(apiKey: deepgramKey)
    }

    private func stopSession() {
        agentClient.disconnect()
        audioManager.stopCapture()
        setState(.idle)
        consoleState.connectionState = .disconnected
        consoleState.log("Session stopped")
    }

    private func interruptSession() {
        audioManager.stopPlayback()
        setState(.listening)
        consoleState.log("Interrupted -- resuming listen")
    }

    private func setState(_ newState: AppState) {
        consoleState.appState = newState
    }

    private func resolveApproval(callId: String, approved: Bool, always: Bool) {
        guard let continuation = pendingContinuations.removeValue(forKey: callId) else { return }
        if approved, always, let approval = consoleState.pendingApprovals.first(where: { $0.id == callId }) {
            alwaysApprovedTools.insert(approval.toolName)
            consoleState.log("Auto-approve enabled for \(approval.toolName)")
        }
        consoleState.removeApproval(callId: callId)
        continuation.resume(returning: approved)
    }
}

// MARK: - FunctionCallApprovalDelegate

extension AppDelegate: FunctionCallApprovalDelegate {
    nonisolated func functionCallNeedsApproval(id: String, name: String, args: String) async -> Bool {
        await _requestApproval(id: id, name: name, args: args)
    }

    /// MainActor-isolated helper so we can safely access state and continuations.
    private func _requestApproval(id: String, name: String, args: String) async -> Bool {
        if alwaysApprovedTools.contains(name) {
            consoleState.log("Auto-approved \(name)")
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingContinuations[id] = continuation
                consoleState.addApproval(callId: id, toolName: name, argsDescription: args)
                consoleState.log("Awaiting approval for \(name)")
            }
        } onCancel: {
            // Timeout or task cancellation -- clean up on MainActor
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let continuation = self.pendingContinuations.removeValue(forKey: id) {
                    self.consoleState.removeApproval(callId: id)
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

// MARK: - HotkeyManagerDelegate

extension AppDelegate: HotkeyManagerDelegate {
    func hotkeyManagerDidDetectKeyDown(_ manager: HotkeyManager) {
        toggleListening()
    }

    func hotkeyManagerDidDetectKeyUp(_ manager: HotkeyManager) {}
}

// MARK: - DeepgramAgentDelegate

extension AppDelegate: DeepgramAgentDelegate {
    nonisolated func agentDidConnect(requestId: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.consoleState.connectionState = .connected
            self.consoleState.log("Voice Agent connected (request: \(requestId))")

            guard let orKey = self.openRouterAPIKey, let registry = self.toolRegistry else {
                self.consoleState.log("Missing OpenRouter key or tool registry", level: .error)
                return
            }

            let settings = VoiceAgentSettingsBuilder.build(
                config: self.config,
                toolRegistry: registry,
                openRouterKey: orKey,
                greeting: "Hey there!"
            )
            self.agentClient.sendSettings(settings)
        }
    }

    nonisolated func agentDidDisconnect(error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.consoleState.connectionState = .disconnected
            if let error {
                self.consoleState.log("Voice Agent disconnected: \(error.localizedDescription)", level: .warning)
            } else {
                self.consoleState.log("Voice Agent disconnected")
            }
            self.audioManager.stopCapture()
            self.setState(.idle)
        }
    }

    nonisolated func agentSettingsApplied() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.consoleState.log("Voice Agent ready")
            self.setState(.listening)

            self.audioManager.startCapture { [weak self] data in
                self?.agentClient.sendAudio(data)
            }
        }
    }

    nonisolated func agentUserStartedSpeaking() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioManager.stopPlayback()
            self.setState(.listening)
        }
    }

    nonisolated func agentDidStartThinking(content: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setState(.thinking)
        }
    }

    nonisolated func agentDidStartSpeaking(totalLatency: Double, ttsLatency: Double, llmLatency: Double) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setState(.speaking)
            let totalMs = Int(totalLatency * 1000)
            let ttsMs = Int(ttsLatency * 1000)
            let llmMs = Int(llmLatency * 1000)
            self.consoleState.log("Latency -- total: \(totalMs)ms, tts: \(ttsMs)ms, llm: \(llmMs)ms", level: .debug)
        }
    }

    nonisolated func agentDidReceiveAudio(_ data: Data) {
        audioManager.enqueueAudio(data: data)
    }

    nonisolated func agentAudioDone() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.consoleState.appState == .speaking {
                self.setState(.listening)
            }
        }
    }

    nonisolated func agentDidReceiveTranscript(role: String, content: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.consoleState.addTranscript(role: role, text: content, isFinal: true)
            self.consoleState.log("\(role): \(content)")
        }
    }

    nonisolated func agentDidReceiveFunctionCall(id: String, name: String, arguments: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.consoleState.log("Tool call: \(name)(\(arguments.prefix(100)))")

            guard let handler = self.functionCallHandler else {
                self.consoleState.log("No function call handler -- returning error", level: .warning)
                self.agentClient.sendFunctionCallResponse(id: id, name: name, output: "Error: tool system not initialized")
                return
            }

            handler.handle(id: id, name: name, arguments: arguments)
        }
    }

    nonisolated func agentDidReceiveError(message: String) {
        Task { @MainActor [weak self] in
            self?.consoleState.log("Agent error: \(message)", level: .error)
        }
    }

    nonisolated func agentDidReceiveWarning(message: String) {
        Task { @MainActor [weak self] in
            self?.consoleState.log("Agent warning: \(message)", level: .warning)
        }
    }
}
