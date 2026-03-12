import Foundation

private final class SendOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func claim() -> Bool {
        lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
    }
}

@MainActor
final class VoiceAgentRuntime {
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
    private var observers: [NSObjectProtocol] = []

    private var agentReady = false
    private var pendingCaptureStart = false
    private var reconnectReason: String?
    private var allowAssistantPlayback = false
    private var isShuttingDown = false

    private var listenRequestStartedAt: DispatchTime?
    private var captureStartedAt: DispatchTime?
    private var firstAudioSendAt: DispatchTime?
    private var firstAudioReceiveAt: DispatchTime?
    private var firstPlaybackAt: DispatchTime?

    lazy var consoleActions: DevConsoleActions = DevConsoleActions(
        onTalkToggle: { [weak self] in self?.toggleListening() },
        onInterrupt: { [weak self] in self?.interruptSession() },
        onApprove: { [weak self] callId, always in self?.resolveApproval(callId: callId, approved: true, always: always) },
        onReject: { [weak self] callId, always in self?.resolveApproval(callId: callId, approved: false, always: always) },
        onClearLog: { [weak self] in self?.consoleState.clearLog() }
    )

    func start() {
        hotkeyManager.delegate = self
        agentClient.delegate = self
        consoleState.audioManager = audioManager
        audioManager.onPlaybackStarted = { [weak self] in
            Task { @MainActor [weak self] in
                self?.recordPlaybackStarted()
            }
        }
        audioManager.preparePlayback()

        Task {
            let granted = await audioManager.requestPermission()
            consoleState.log(
                "Mic permission: \(granted ? "granted" : "denied")",
                level: granted ? .info : .warning
            )
        }

        DeepVoiceConfig.bootstrapStorage()
        loadConfig(logChange: true)
        loadAPIKeys(logStatuses: true)
        rebuildTooling()
        installObservers()

        consoleState.log("DeepVoice launched (Voice Agent mode)")
        ensureWarmSession(reason: "launch", logIfUnavailable: false)
    }

    func shutdown() {
        isShuttingDown = true
        removeObservers()
        agentClient.disconnect()
        audioManager.shutdown()
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
        guard ensureKeysForSession() else { return }

        pendingCaptureStart = true
        allowAssistantPlayback = true
        audioManager.resumePlayback()
        resetTurnLatencyMetrics()
        listenRequestStartedAt = DispatchTime.now()

        if agentClient.isConnected, agentReady {
            startCaptureIfNeeded()
        } else {
            consoleState.log("Preparing Voice Agent...")
            ensureWarmSession(reason: "talk request")
        }
    }

    private func stopSession() {
        pendingCaptureStart = false
        allowAssistantPlayback = false
        agentReady = agentReady && agentClient.isConnected
        resetTurnLatencyMetrics()
        audioManager.stopCapture()
        audioManager.suppressPlayback()
        setState(.idle)
        consoleState.log("Microphone stopped; Voice Agent kept warm")
    }

    private func interruptSession() {
        pendingCaptureStart = true
        allowAssistantPlayback = true
        resetTurnLatencyMetrics()
        listenRequestStartedAt = DispatchTime.now()
        audioManager.suppressPlayback()

        if agentClient.isConnected, agentReady {
            startCaptureIfNeeded()
        } else {
            ensureWarmSession(reason: "interrupt")
        }

        consoleState.log("Interrupted -- playback suppressed, resuming listen")
    }

    private func startCaptureIfNeeded() {
        guard pendingCaptureStart else { return }
        guard agentClient.isConnected, agentReady else { return }

        if audioManager.isCapturing {
            setState(.listening)
            return
        }

        let agentClient = self.agentClient
        let firstSendFlag = SendOnceFlag()
        audioManager.startCapture(
            onCaptureStarted: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.recordCaptureStarted()
                }
            },
            onAudioData: { [weak self, agentClient] data in
                agentClient.sendAudio(data)
                guard firstSendFlag.claim() else { return }
                Task { @MainActor [weak self] in
                    self?.recordFirstOutgoingAudioChunk()
                }
            }
        )
    }

    private func ensureWarmSession(reason: String, logIfUnavailable: Bool = true) {
        guard let deepgramKey = deepgramAPIKey else {
            consoleState.connectionState = .disconnected
            if logIfUnavailable {
                consoleState.log("Cannot connect -- Deepgram API key not set", level: .error)
            }
            return
        }

        guard openRouterAPIKey != nil else {
            consoleState.connectionState = .disconnected
            if logIfUnavailable {
                consoleState.log("Cannot connect -- OpenRouter API key not set", level: .error)
            }
            return
        }

        guard !isShuttingDown else { return }
        guard !agentClient.isConnected, consoleState.connectionState != .connecting else { return }

        agentReady = false
        consoleState.connectionState = .connecting
        consoleState.log("Connecting to Voice Agent (\(reason))")
        agentClient.connect(apiKey: deepgramKey)
    }

    private func refreshWarmSession(reason: String) {
        let shouldResumeCapture = pendingCaptureStart || audioManager.isCapturing || consoleState.appState != .idle
        pendingCaptureStart = shouldResumeCapture
        allowAssistantPlayback = shouldResumeCapture
        agentReady = false
        audioManager.stopCapture()
        audioManager.suppressPlayback()
        resetTurnLatencyMetrics()

        guard deepgramAPIKey != nil, openRouterAPIKey != nil else {
            reconnectReason = nil
            pendingCaptureStart = false
            allowAssistantPlayback = false
            if agentClient.isConnected || consoleState.connectionState == .connecting {
                consoleState.log("Disconnecting Voice Agent -- required keys changed", level: .warning)
                agentClient.disconnect()
            } else {
                consoleState.connectionState = .disconnected
                setState(.idle)
            }
            return
        }

        reconnectReason = reason
        if agentClient.isConnected || consoleState.connectionState == .connecting {
            consoleState.log("Refreshing Voice Agent (\(reason))")
            agentClient.disconnect()
        } else {
            ensureWarmSession(reason: reason)
        }
    }

    private func ensureKeysForSession() -> Bool {
        guard deepgramAPIKey != nil else {
            consoleState.log("Cannot start -- Deepgram API key not set", level: .error)
            return false
        }
        guard openRouterAPIKey != nil else {
            consoleState.log("Cannot start -- OpenRouter API key not set", level: .error)
            return false
        }
        return true
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

    // MARK: - Runtime config

    private func installObservers() {
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(forName: .deepVoiceConfigDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleConfigDidChange()
                }
            }
        )

        observers.append(
            center.addObserver(forName: .deepVoiceAPIKeysDidChange, object: nil, queue: .main) { [weak self] notification in
                let changedAccount = (notification.userInfo?["account"] as? String).flatMap(KeychainAccount.init(rawValue:))
                Task { @MainActor [weak self] in
                    self?.handleAPIKeysDidChange(changedAccount: changedAccount)
                }
            }
        )
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func handleConfigDidChange() {
        let previous = config
        loadConfig(logChange: false)
        guard config != previous else { return }
        let updatePlan = config.sessionUpdatePlan(comparedTo: previous)

        rebuildTooling()
        consoleState.log(
            "Config updated (stt: \(config.sttModel), llm: \(config.llmModel), voice: \(config.voice))"
        )

        if applyLiveConfigUpdateIfPossible(updatePlan) {
            return
        }

        refreshWarmSession(reason: "settings change")
    }

    private func handleAPIKeysDidChange(changedAccount: KeychainAccount?) {
        loadAPIKeys(logStatuses: false)

        if let changedAccount {
            let configured = KeychainHelper.loadAPIKey(for: changedAccount) != nil
            consoleState.log(
                "\(changedAccount.rawValue): \(configured ? "configured" : "not set")",
                level: configured ? .info : .warning
            )
        }

        switch changedAccount {
        case .deepgramAPIKey, .openRouterAPIKey:
            refreshWarmSession(reason: "API key change")
        case .openAIAPIKey, .none:
            break
        }
    }

    private func loadConfig(logChange: Bool) {
        if let loaded = try? DeepVoiceConfig.load() {
            config = loaded
        } else {
            config = .defaults
        }

        if logChange {
            consoleState.log("Config loaded (stt: \(config.sttModel), llm: \(config.llmProvider)/\(config.llmModel))")
        }
    }

    private func loadAPIKeys(logStatuses: Bool) {
        deepgramAPIKey = KeychainHelper.loadAPIKey(for: .deepgramAPIKey)
        openRouterAPIKey = KeychainHelper.loadAPIKey(for: .openRouterAPIKey)

        if logStatuses {
            for account in KeychainAccount.allCases {
                if KeychainHelper.loadAPIKey(for: account) != nil {
                    consoleState.log("\(account.rawValue): configured")
                } else {
                    consoleState.log("\(account.rawValue): not set", level: .warning)
                }
            }
        }
    }

    private func applyLiveConfigUpdateIfPossible(_ updatePlan: SessionConfigUpdatePlan) -> Bool {
        if updatePlan.requiresReconnect {
            return false
        }

        guard updatePlan.needsLiveAgentUpdate else {
            return true
        }

        guard agentClient.isConnected else {
            return true
        }

        guard agentReady else {
            consoleState.log("Settings changed while Voice Agent was reconfiguring; refreshing warm session", level: .warning)
            return false
        }

        if updatePlan.updateThink {
            guard let registry = toolRegistry, let openRouterAPIKey else {
                return false
            }
            let thinkConfig = VoiceAgentSettingsBuilder.buildThinkConfig(
                config: config,
                toolRegistry: registry,
                openRouterKey: openRouterAPIKey
            )
            agentClient.updateThink(thinkConfig)
            consoleState.log("Applied live Think update")
        }

        if updatePlan.updateSpeak {
            agentClient.updateSpeak(VoiceAgentSettingsBuilder.buildSpeakConfig(config: config))
            consoleState.log("Applied live Speak update")
        }

        return true
    }

    private func rebuildTooling() {
        let registry = ToolRegistry.withDefaultTools(config: config)
        DesktopTools.register(on: registry, executor: desktopContextToolExecutor)
        toolRegistry = registry

        let handler = FunctionCallHandler(toolRegistry: registry, agentClient: agentClient)
        handler.approvalDelegate = self
        functionCallHandler = handler
        alwaysApprovedTools.formIntersection(Set(registry.registeredToolNames()))
    }

    // MARK: - Latency metrics

    private func resetTurnLatencyMetrics() {
        listenRequestStartedAt = nil
        captureStartedAt = nil
        firstAudioSendAt = nil
        firstAudioReceiveAt = nil
        firstPlaybackAt = nil
    }

    private func recordCaptureStarted() {
        captureStartedAt = DispatchTime.now()
        setState(.listening)

        if let listenRequestStartedAt {
            consoleState.log(
                "Latency -- hotkey to capture start: \(elapsedMilliseconds(since: listenRequestStartedAt))ms",
                level: .debug
            )
        }
    }

    private func recordFirstOutgoingAudioChunk() {
        guard firstAudioSendAt == nil else { return }
        let now = DispatchTime.now()
        firstAudioSendAt = now

        if let captureStartedAt {
            consoleState.log(
                "Latency -- capture start to first audio send: \(elapsedMilliseconds(since: captureStartedAt, to: now))ms",
                level: .debug
            )
        }
    }

    private func recordFirstInboundAudioChunk() {
        guard firstAudioReceiveAt == nil else { return }
        let now = DispatchTime.now()
        firstAudioReceiveAt = now

        if let firstAudioSendAt {
            consoleState.log(
                "Latency -- first audio send to first audio receive: \(elapsedMilliseconds(since: firstAudioSendAt, to: now))ms",
                level: .debug
            )
        }
    }

    private func recordPlaybackStarted() {
        guard firstPlaybackAt == nil else { return }
        let now = DispatchTime.now()
        firstPlaybackAt = now

        if let firstAudioReceiveAt {
            consoleState.log(
                "Latency -- first audio receive to playback start: \(elapsedMilliseconds(since: firstAudioReceiveAt, to: now))ms",
                level: .debug
            )
        }
        if let listenRequestStartedAt {
            consoleState.log(
                "Latency -- hotkey to playback start: \(elapsedMilliseconds(since: listenRequestStartedAt, to: now))ms",
                level: .debug
            )
        }
    }

    private func elapsedMilliseconds(since start: DispatchTime, to end: DispatchTime = DispatchTime.now()) -> Int {
        let delta = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Int(delta / 1_000_000)
    }
}

// MARK: - FunctionCallApprovalDelegate

extension VoiceAgentRuntime: FunctionCallApprovalDelegate {
    nonisolated func functionCallNeedsApproval(id: String, name: String, args: String) async -> Bool {
        await _requestApproval(id: id, name: name, args: args)
    }

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

extension VoiceAgentRuntime: HotkeyManagerDelegate {
    func hotkeyManagerDidDetectKeyDown(_ manager: HotkeyManager) {
        toggleListening()
    }

    func hotkeyManagerDidDetectKeyUp(_ manager: HotkeyManager) {}
}

// MARK: - DeepgramAgentDelegate

extension VoiceAgentRuntime: DeepgramAgentDelegate {
    nonisolated func agentDidConnect(requestId: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.consoleState.connectionState = .connected
            self.agentReady = false
            self.consoleState.log("Voice Agent connected (request: \(requestId))")

            guard let orKey = self.openRouterAPIKey, let registry = self.toolRegistry else {
                self.consoleState.log("Missing OpenRouter key or tool registry", level: .error)
                self.agentClient.disconnect()
                return
            }

            let settings = VoiceAgentSettingsBuilder.build(
                config: self.config,
                toolRegistry: registry,
                openRouterKey: orKey,
                greeting: nil
            )
            self.agentClient.sendSettings(settings)
        }
    }

    nonisolated func agentDidDisconnect(error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.consoleState.connectionState = .disconnected
            self.agentReady = false
            self.audioManager.stopCapture()
            self.audioManager.suppressPlayback()

            if self.isShuttingDown {
                return
            }

            if let reconnectReason = self.reconnectReason {
                self.reconnectReason = nil
                self.consoleState.log("Voice Agent disconnected -- reconnecting for \(reconnectReason)")
                self.ensureWarmSession(reason: reconnectReason)
                return
            }

            if let error {
                self.consoleState.log("Voice Agent disconnected: \(error.localizedDescription)", level: .warning)
            } else {
                self.consoleState.log("Voice Agent disconnected")
            }

            if !self.pendingCaptureStart {
                self.allowAssistantPlayback = false
                self.setState(.idle)
            }
        }
    }

    nonisolated func agentSettingsApplied() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.agentReady = true
            self.consoleState.log("Voice Agent ready")

            if self.pendingCaptureStart {
                self.startCaptureIfNeeded()
            } else {
                self.setState(.idle)
            }
        }
    }

    nonisolated func agentUserStartedSpeaking() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.pendingCaptureStart else { return }
            self.audioManager.suppressPlayback()
            self.setState(.listening)
        }
    }

    nonisolated func agentDidStartThinking(content: String) {
        _ = content
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.pendingCaptureStart else { return }
            self.setState(.thinking)
        }
    }

    nonisolated func agentDidStartSpeaking(totalLatency: Double, ttsLatency: Double, llmLatency: Double) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if self.allowAssistantPlayback {
                self.audioManager.resumePlayback()
                self.setState(.speaking)
            }

            let totalMs = Int(totalLatency * 1000)
            let ttsMs = Int(ttsLatency * 1000)
            let llmMs = Int(llmLatency * 1000)
            self.consoleState.log(
                "Latency -- total: \(totalMs)ms, tts: \(ttsMs)ms, llm: \(llmMs)ms",
                level: .debug
            )
        }
    }

    nonisolated func agentDidReceiveAudio(_ data: Data) {
        Task { @MainActor [weak self] in
            guard let self, self.pendingCaptureStart || self.allowAssistantPlayback else { return }
            self.recordFirstInboundAudioChunk()
        }
        audioManager.enqueueAudio(data: data)
    }

    nonisolated func agentAudioDone() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.pendingCaptureStart {
                self.setState(.listening)
            } else {
                self.allowAssistantPlayback = false
                self.setState(.idle)
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
            self?.setState(.error)
        }
    }

    nonisolated func agentDidReceiveWarning(message: String) {
        Task { @MainActor [weak self] in
            self?.consoleState.log("Agent warning: \(message)", level: .warning)
        }
    }
}
