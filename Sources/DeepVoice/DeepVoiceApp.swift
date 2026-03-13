import AppKit
import SwiftUI

@main
struct DeepVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("DeepVoice Console") {
            DevConsoleView(state: appDelegate.consoleState, actions: appDelegate.consoleActions)
                .environment(appDelegate.configStore)
        }
        Settings {
            SettingsView()
                .environment(appDelegate.configStore)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let consoleState = DevConsoleState()
    let configStore = ConfigStore()
    let hotkeyManager = HotkeyManager()
    let audioManager = AudioManager()
    let agentClient = DeepgramAgentClient()
    let desktopContextToolExecutor = DesktopContextToolExecutor()
    private(set) var toolRegistry: ToolRegistry?
    private(set) var functionCallHandler: FunctionCallHandler?
    private var companionPanel: CompanionPanel?

    private var pendingContinuations: [String: CheckedContinuation<Bool, Never>] = [:]
    private var alwaysApprovedTools: Set<String> = []
    private var isSessionActive = false
    private var isAgentThinking = false
    private var thinkingResetTask: Task<Void, Never>?
    private let thinkingHoldDuration: UInt64 = 900_000_000

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
        audioManager.setRouteMode(configStore.config.audioRouteMode)

        audioManager.onStateChange = { [weak self] capturing, playing in
            guard let self else { return }
            self.consoleState.isCapturing = capturing
            self.consoleState.isPlaying = playing
            self.resolveAppState(reason: "audio state changed")
            self.consoleState.log("Audio state: capturing=\(capturing), playing=\(playing)", level: .debug)
        }
        audioManager.onCaptureEnergy = { [weak self] energy in
            self?.consoleState.captureEnergy = CGFloat(energy)
        }
        audioManager.onPlaybackEnergy = { [weak self] energy in
            self?.consoleState.playbackEnergy = CGFloat(energy)
        }
        audioManager.onCaptureError = { [weak self] message in
            self?.consoleState.log(message, level: .error)
        }

        Task {
            let granted = await audioManager.requestPermission()
            consoleState.log("Mic permission: \(granted ? "granted" : "denied")",
                            level: granted ? .info : .warning)
        }

        DeepVoiceConfig.bootstrapStorage()

        consoleState.log("Config loaded (llm: \(configStore.config.llmProvider)/\(configStore.config.llmModel))")
        consoleState.log("Audio route mode: \(configStore.config.audioRouteMode.title)")

        for account in KeychainAccount.allCases {
            if KeychainHelper.loadAPIKey(for: account) != nil {
                consoleState.log("\(account.rawValue): configured")
            } else {
                consoleState.log("\(account.rawValue): not set", level: .warning)
            }
        }

        let registry = ToolRegistry.withDefaultTools()
        registry.setConfigStore(configStore)
        DesktopTools.register(on: registry, executor: desktopContextToolExecutor)
        toolRegistry = registry

        // Keep registry in sync with live config changes
        observeConfigChanges(registry: registry)

        let handler = FunctionCallHandler(
            toolRegistry: registry,
            agentClient: agentClient
        )
        handler.approvalDelegate = self
        functionCallHandler = handler

        consoleState.log("DeepVoice launched (Voice Agent mode)")

        let panel = CompanionPanel(state: consoleState, actions: consoleActions, configStore: configStore)
        panel.orderFront(nil)
        companionPanel = panel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running while companion panel is visible (NSPanel doesn't count as a "window" here)
        !(companionPanel?.isVisible ?? false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentClient.disconnect()
        audioManager.stopCapture()
        resetSessionState()
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
        // Reload keys in case they were changed in Settings
        configStore.reloadAPIKeys()

        guard let deepgramKey = configStore.deepgramAPIKey else {
            consoleState.log("Cannot start -- Deepgram API key not set", level: .error)
            return
        }

        consoleState.connectionState = .connecting
        isSessionActive = true
        resolveAppState(reason: "session starting")
        consoleState.log("Connecting to Voice Agent...")

        agentClient.connect(apiKey: deepgramKey)
    }

    private func stopSession() {
        agentClient.disconnect()
        audioManager.stopCapture()
        resetSessionState()
        consoleState.connectionState = .disconnected
        consoleState.log("Session stopped")
    }

    private func interruptSession() {
        audioManager.stopPlayback()
        isAgentThinking = false
        thinkingResetTask?.cancel()
        resolveAppState(reason: "interrupt")
        consoleState.log("Interrupted -- resuming listen")
    }

    private func resetSessionState() {
        thinkingResetTask?.cancel()
        thinkingResetTask = nil
        isSessionActive = false
        isAgentThinking = false
        resolveAppState(reason: "session reset")
    }

    private func holdThinkingState() {
        thinkingResetTask?.cancel()
        let holdDuration = thinkingHoldDuration

        thinkingResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: holdDuration)
            guard let self, !Task.isCancelled else { return }
            self.isAgentThinking = false
            self.resolveAppState(reason: "thinking timeout")
        }
    }

    private func resolveAppState(reason: String) {
        let newState: AppState

        if !isSessionActive {
            newState = .idle
        } else if consoleState.isPlaying {
            newState = .speaking
        } else if isAgentThinking {
            newState = .thinking
        } else {
            newState = .listening
        }

        if consoleState.appState != newState {
            consoleState.log("UI state -> \(newState.rawValue) (\(reason))", level: .debug)
            consoleState.appState = newState
        }
    }

    private func observeConfigChanges(registry: ToolRegistry) {
        // Use withObservationTracking to re-sync when confirmDestructive or safeMode changes
        func observe() {
            withObservationTracking {
                _ = configStore.config.confirmDestructive
                _ = configStore.config.safeMode
                _ = configStore.config.audioRouteMode
            } onChange: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    registry.updateConfirmDestructive(self.configStore.config.confirmDestructive)
                    registry.updateSafeMode(self.configStore.config.safeMode)
                    self.audioManager.setRouteMode(self.configStore.config.audioRouteMode)
                    self.consoleState.log("Audio route mode updated to \(self.configStore.config.audioRouteMode.title)")
                    if self.consoleState.connectionState != .disconnected {
                        self.consoleState.log("Audio route changes apply on the next session", level: .warning)
                    }
                    observe() // re-register for next change
                }
            }
        }
        observe()
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
    func functionCallNeedsApproval(id: String, name: String, args: String) async -> Bool {
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

            guard let orKey = self.configStore.openRouterAPIKey, let registry = self.toolRegistry else {
                self.consoleState.log("Missing OpenRouter key or tool registry", level: .error)
                return
            }

            // Skip greeting on reconnect when we have conversation history
            let hasHistory = self.consoleState.transcriptEntries.contains { $0.isFinal && !$0.text.isEmpty }
            let settings = VoiceAgentSettingsBuilder.build(
                config: self.configStore.config,
                toolRegistry: registry,
                openRouterKey: orKey,
                greeting: hasHistory ? nil : "Hey there"
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
            self.resetSessionState()
        }
    }

    nonisolated func agentSettingsApplied() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.consoleState.log("Voice Agent ready")

            // Inject previous conversation history so the agent has context
            self.injectConversationHistory()

            self.isSessionActive = true
            self.isAgentThinking = false
            self.resolveAppState(reason: "settings applied")

            // Brief delay so greeting audio can start playing before capture
            // engine init (VPIO setup can disrupt in-progress playback)
            try? await Task.sleep(nanoseconds: 500_000_000)

            self.audioManager.startCapture { [weak self] data in
                self?.agentClient.sendAudio(data)
            }
        }
    }

    /// Inject transcript history into the new Voice Agent session via UpdatePrompt.
    /// Uses prompt context instead of individual message injection to avoid the
    /// agent re-executing tool calls or responding to old messages.
    private func injectConversationHistory() {
        let entries = consoleState.transcriptEntries.filter { $0.isFinal && !$0.text.isEmpty }
        guard !entries.isEmpty else { return }

        // Skip greetings
        let meaningful = entries.filter { !($0.role == "assistant" && $0.text == "Hey there") }
        guard !meaningful.isEmpty else { return }

        // Build a conversation summary to prepend to the system prompt
        var lines: [String] = []
        for entry in meaningful {
            let prefix = entry.isUser ? "User" : "You"
            lines.append("\(prefix): \(entry.text)")
        }

        let history = lines.joined(separator: "\n")
        let updatedPrompt = """
            \(Prompts.system)

            CONVERSATION HISTORY

            The following is your conversation with the user from earlier in this session. \
            Do not repeat or re-execute anything from this history. Just use it as context \
            for the ongoing conversation. Continue naturally from where you left off. \
            Do not greet the user again or re-introduce yourself.

            \(history)
            """

        consoleState.log("Resuming with \(meaningful.count) messages of context", level: .debug)
        agentClient.updatePrompt(updatedPrompt)
    }

    nonisolated func agentUserStartedSpeaking() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioManager.stopPlayback()
            self.isAgentThinking = false
            self.thinkingResetTask?.cancel()
            self.resolveAppState(reason: "user speaking")
        }
    }

    nonisolated func agentDidStartThinking(content: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isAgentThinking = true
            self.resolveAppState(reason: "agent thinking")
            self.holdThinkingState()
        }
    }

    nonisolated func agentDidStartSpeaking(totalLatency: Double, ttsLatency: Double, llmLatency: Double) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.thinkingResetTask?.cancel()
            self.isAgentThinking = false
            self.resolveAppState(reason: "agent speaking")
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
        // Don't transition to listening here -- audio buffers may still be playing.
        // The AudioManager playback completion handler updates isPlaying, and
        // the next UserStartedSpeaking or AgentThinking event will drive state.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isAgentThinking = false
            self.resolveAppState(reason: "agent audio done")
            self.consoleState.log("Agent audio stream complete", level: .debug)
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
