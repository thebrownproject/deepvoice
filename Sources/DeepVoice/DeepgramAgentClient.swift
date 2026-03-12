import Foundation
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "DeepgramAgent")

// MARK: - Delegate

protocol DeepgramAgentDelegate: AnyObject {
    func agentDidConnect(requestId: String)
    func agentDidDisconnect(error: Error?)
    func agentSettingsApplied()
    func agentDidReceiveTranscript(role: String, content: String)
    func agentDidStartThinking(content: String)
    func agentDidStartSpeaking(totalLatency: Double, ttsLatency: Double, llmLatency: Double)
    func agentDidReceiveAudio(_ data: Data)
    func agentAudioDone()
    func agentDidReceiveFunctionCall(id: String, name: String, arguments: String)
    func agentUserStartedSpeaking()
    func agentDidReceiveError(message: String)
    func agentDidReceiveWarning(message: String)
}

// Default no-op implementations
extension DeepgramAgentDelegate {
    func agentDidConnect(requestId: String) {}
    func agentDidDisconnect(error: Error?) {}
    func agentSettingsApplied() {}
    func agentDidReceiveTranscript(role: String, content: String) {}
    func agentDidStartThinking(content: String) {}
    func agentDidStartSpeaking(totalLatency: Double, ttsLatency: Double, llmLatency: Double) {}
    func agentDidReceiveAudio(_ data: Data) {}
    func agentAudioDone() {}
    func agentDidReceiveFunctionCall(id: String, name: String, arguments: String) {}
    func agentUserStartedSpeaking() {}
    func agentDidReceiveError(message: String) {}
    func agentDidReceiveWarning(message: String) {}
}

// MARK: - Error types

enum DeepgramAgentError: LocalizedError {
    case notConnected
    case serializationFailed
    case maxReconnectAttemptsReached

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to Deepgram Voice Agent"
        case .serializationFailed: "Failed to serialize message"
        case .maxReconnectAttemptsReached: "Max reconnect attempts reached"
        }
    }
}

// MARK: - Client

final class DeepgramAgentClient: NSObject, @unchecked Sendable {
    weak var delegate: DeepgramAgentDelegate?

    private(set) var isConnected: Bool = false

    private let queue = DispatchQueue(label: "com.deepvoice.deepgram-agent")
    private let endpoint = URL(string: "wss://agent.deepgram.com/v1/agent/converse")!

    private var apiKey: String?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var keepaliveTimer: DispatchSourceTimer?
    private var intentionalDisconnect = false
    private var reconnectAttempt = 0
    private var lastOutboundActivity = Date.distantPast

    private let maxReconnectAttempts = 5
    private let maxReconnectDelay: TimeInterval = 30.0

    // MARK: - Public API

    func connect(apiKey: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.apiKey = apiKey
            self.intentionalDisconnect = false
            self.reconnectAttempt = 0
            self.doConnect()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.intentionalDisconnect = true
            self.teardown()
            self.delegate?.agentDidDisconnect(error: nil)
        }
    }

    func sendSettings(_ settings: [String: Any]) {
        var message = settings
        message["type"] = "Settings"
        sendJSON(message)
    }

    func sendAudio(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.isConnected, let task = self.task else { return }
            self.recordOutboundActivity()
            task.send(.data(data)) { error in
                if let error {
                    log.error("Audio send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// V1 format: type=FunctionCallResponse, id, name, content
    func sendFunctionCallResponse(id: String, name: String, output: String) {
        sendJSON([
            "type": "FunctionCallResponse",
            "id": id,
            "name": name,
            "content": output,
        ])
    }

    func updateSpeak(_ config: [String: Any]) {
        sendJSON(["type": "UpdateSpeak", "speak": config])
    }

    func updateThink(_ config: [String: Any]) {
        sendJSON(["type": "UpdateThink", "think": config])
    }

    func updatePrompt(_ prompt: String) {
        sendJSON(["type": "UpdatePrompt", "prompt": prompt])
    }

    func injectUserMessage(_ text: String) {
        sendJSON(["type": "InjectUserMessage", "content": text])
    }

    func injectAgentMessage(_ text: String) {
        sendJSON(["type": "InjectAgentMessage", "content": text])
    }

    // MARK: - Connection lifecycle

    private func doConnect() {
        teardown()

        guard let apiKey else {
            log.error("No API key set")
            return
        }

        var request = URLRequest(url: endpoint)
        request.addValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)

        self.session = session
        self.task = task
        task.resume()
        log.info("Connecting to Deepgram Voice Agent...")
    }

    private func startReceiving() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.startReceiving()
                case .failure(let error):
                    if !self.intentionalDisconnect {
                        log.error("Receive error: \(error.localizedDescription)")
                    }
                    self.handleDisconnect(error: self.intentionalDisconnect ? nil : error)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            // Binary frame = audio from TTS
            delegate?.agentDidReceiveAudio(data)
        case .string(let text):
            handleTextMessage(text)
        @unknown default:
            break
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            log.warning("Unrecognized message from Voice Agent")
            return
        }

        switch type {
        case "Welcome":
            let requestId = json["request_id"] as? String ?? ""
            log.info("Welcome (request_id: \(requestId))")
            delegate?.agentDidConnect(requestId: requestId)

        case "SettingsApplied":
            log.info("Settings applied")
            delegate?.agentSettingsApplied()

        case "ConversationText":
            let role = json["role"] as? String ?? "unknown"
            let content = json["content"] as? String ?? ""
            delegate?.agentDidReceiveTranscript(role: role, content: content)

        case "AgentThinking":
            let content = json["content"] as? String ?? ""
            delegate?.agentDidStartThinking(content: content)

        case "AgentStartedSpeaking":
            // Latency values from API are in seconds
            let total = json["total_latency"] as? Double ?? 0
            let tts = json["tts_latency"] as? Double ?? 0
            let llm = json["ttt_latency"] as? Double ?? 0
            log.info("Agent speaking (latency: \(String(format: "%.3f", total))s, tts: \(String(format: "%.3f", tts))s, llm: \(String(format: "%.3f", llm))s)")
            delegate?.agentDidStartSpeaking(totalLatency: total, ttsLatency: tts, llmLatency: llm)

        case "AgentAudioDone":
            delegate?.agentAudioDone()

        case "FunctionCallRequest":
            handleFunctionCallRequest(json)

        case "UserStartedSpeaking":
            delegate?.agentUserStartedSpeaking()

        case "Error":
            let desc = json["description"] as? String ?? json["message"] as? String ?? "Unknown error"
            log.error("Agent error: \(desc)")
            delegate?.agentDidReceiveError(message: desc)

        case "Warning":
            let desc = json["description"] as? String ?? json["message"] as? String ?? "Unknown warning"
            log.warning("Agent warning: \(desc)")
            delegate?.agentDidReceiveWarning(message: desc)

        case "PromptUpdated", "SpeakUpdated", "ThinkUpdated":
            log.info("\(type) confirmed")

        case "InjectionRefused":
            let reason = json["message"] as? String ?? "unknown reason"
            log.warning("Injection refused: \(reason)")
            delegate?.agentDidReceiveWarning(message: "Injection refused: \(reason)")

        case "FunctionCallResponse":
            // Server-side function execution result -- log only
            log.debug("Server function call response received")

        default:
            log.debug("Unhandled Voice Agent event: \(type)")
        }
    }

    /// V1 format: functions array with id, name, arguments, client_side
    private func handleFunctionCallRequest(_ json: [String: Any]) {
        guard let functions = json["functions"] as? [[String: Any]] else {
            // Fall back to early-access format
            if let name = json["function_name"] as? String,
               let callId = json["function_call_id"] as? String {
                let input = json["input"]
                let argsString: String
                if let inputDict = input as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: inputDict),
                   let str = String(data: data, encoding: .utf8) {
                    argsString = str
                } else {
                    argsString = "{}"
                }
                delegate?.agentDidReceiveFunctionCall(id: callId, name: name, arguments: argsString)
            }
            return
        }

        for fn in functions {
            guard let id = fn["id"] as? String,
                  let name = fn["name"] as? String else { continue }
            let clientSide = fn["client_side"] as? Bool ?? true
            guard clientSide else { continue } // Server handles non-client-side functions
            let arguments = fn["arguments"] as? String ?? "{}"
            delegate?.agentDidReceiveFunctionCall(id: id, name: name, arguments: arguments)
        }
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        stopKeepalive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.sendKeepAliveIfIdle()
        }
        timer.resume()
        keepaliveTimer = timer
        scheduleNextKeepAlive()
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    // MARK: - Reconnection

    private func handleDisconnect(error: Error?) {
        let wasConnected = isConnected
        teardown()

        if wasConnected {
            delegate?.agentDidDisconnect(error: error)
        }

        guard !intentionalDisconnect, reconnectAttempt < maxReconnectAttempts else {
            if reconnectAttempt >= maxReconnectAttempts {
                log.error("Max reconnect attempts (\(self.maxReconnectAttempts)) reached")
                delegate?.agentDidReceiveError(message: DeepgramAgentError.maxReconnectAttemptsReached.localizedDescription)
            }
            return
        }

        // Exponential backoff: 1s, 2s, 4s, 8s, 16s capped at 30s
        let delay = min(pow(2.0, Double(reconnectAttempt)), maxReconnectDelay)
        reconnectAttempt += 1
        log.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempt)/\(self.maxReconnectAttempts))")

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalDisconnect else { return }
            self.doConnect()
        }
    }

    private func teardown() {
        stopKeepalive()
        isConnected = false
        lastOutboundActivity = Date.distantPast
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Send helpers

    private func sendJSON(_ payload: [String: Any]) {
        queue.async { [weak self] in
            self?.sendJSONOnQueue(payload)
        }
    }

    private func sendJSONOnQueue(_ payload: [String: Any]) {
        guard isConnected, let task = task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            log.error("Failed to serialize JSON message")
            return
        }
        recordOutboundActivity()
        task.send(.string(text)) { error in
            if let error {
                log.error("Send failed: \(error.localizedDescription)")
            }
        }
    }

    private func sendKeepAliveIfIdle() {
        guard isConnected else { return }
        let now = Date()
        let nextDelay = VoiceAgentKeepAlivePolicy.nextDelay(since: lastOutboundActivity, now: now)
        guard nextDelay == 0 else {
            scheduleNextKeepAlive(after: nextDelay)
            return
        }
        sendJSONOnQueue(["type": "KeepAlive"])
    }

    private func scheduleNextKeepAlive(after delay: TimeInterval? = nil) {
        guard let keepaliveTimer else { return }
        let nextDelay = delay ?? VoiceAgentKeepAlivePolicy.nextDelay(since: lastOutboundActivity)
        keepaliveTimer.schedule(deadline: .now() + nextDelay)
    }

    private func recordOutboundActivity(now: Date = Date()) {
        lastOutboundActivity = now
        scheduleNextKeepAlive(after: VoiceAgentKeepAlivePolicy.interval)
    }
}

// MARK: - URLSessionWebSocketDelegate

extension DeepgramAgentClient: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.reconnectAttempt = 0
            self.recordOutboundActivity()
            self.startKeepalive()
            self.startReceiving()
            log.info("Connected to Deepgram Voice Agent")
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
            log.info("WebSocket closed (code: \(closeCode.rawValue), reason: \(reasonStr))")
            self.handleDisconnect(error: nil)
        }
    }
}
