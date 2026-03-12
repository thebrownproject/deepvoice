import Foundation

/// Builds the Settings message payload for the Deepgram Voice Agent API.
/// The returned dictionary is passed to `DeepgramAgentClient.sendSettings(_:)`,
/// which adds the `"type": "Settings"` wrapper before sending.
///
/// Deepgram Voice Agent docs: https://developers.deepgram.com/docs/configure-voice-agent
enum VoiceAgentSettingsBuilder {

    /// Build a complete Settings payload from config, tools, and API keys.
    /// Uses OpenRouter as a BYO LLM via the `endpoint` field with `provider.type = "open_ai"`
    /// (OpenRouter exposes an OpenAI-compatible chat completions API).
    static func build(
        config: DeepVoiceConfig,
        toolRegistry: ToolRegistry,
        openRouterKey: String,
        greeting: String? = nil
    ) -> [String: Any] {
        var settings: [String: Any] = [
            "audio": audioSettings(),
            "agent": agentSettings(
                config: config,
                toolRegistry: toolRegistry,
                openRouterKey: openRouterKey,
                greeting: greeting
            ),
            "flags": [
                "history": false,
            ],
        ]
        // Opt out of Deepgram model improvement program for privacy
        settings["mip_opt_out"] = true
        return settings
    }

    static func buildThinkConfig(
        config: DeepVoiceConfig,
        toolRegistry: ToolRegistry,
        openRouterKey: String
    ) -> [String: Any] {
        thinkSettings(
            config: config,
            toolRegistry: toolRegistry,
            openRouterKey: openRouterKey
        )
    }

    static func buildSpeakConfig(config: DeepVoiceConfig) -> [String: Any] {
        speakSettings(config: config)
    }

    // MARK: - Audio

    private static func audioSettings() -> [String: Any] {
        [
            "input": [
                "encoding": "linear16",
                "sample_rate": 24000,
            ],
            "output": [
                "encoding": "linear16",
                "sample_rate": 24000,
                "container": "none",
            ],
        ]
    }

    // MARK: - Agent

    private static func agentSettings(
        config: DeepVoiceConfig,
        toolRegistry: ToolRegistry,
        openRouterKey: String,
        greeting: String?
    ) -> [String: Any] {
        var agent: [String: Any] = [
            "listen": listenSettings(config: config),
            "think": thinkSettings(
                config: config,
                toolRegistry: toolRegistry,
                openRouterKey: openRouterKey
            ),
            "speak": speakSettings(config: config),
        ]
        if let greeting, !greeting.isEmpty {
            agent["greeting"] = greeting
        }
        return agent
    }

    // MARK: - Listen (STT)

    private static func listenSettings(config: DeepVoiceConfig) -> [String: Any] {
        var provider: [String: Any] = [
            "type": config.sttProvider,
            "model": config.sttModel,
            "version": sttVersion(for: config.sttModel),
        ]
        if !config.sttModel.lowercased().hasPrefix("flux") {
            provider["smart_format"] = true
        }
        return [
            "provider": provider,
        ]
    }

    private static func sttVersion(for model: String) -> String {
        model.lowercased().hasPrefix("flux") ? "v2" : "v1"
    }

    // MARK: - Think (LLM)

    /// BYO LLM via OpenRouter: set provider.type to "open_ai" (OpenAI-compatible)
    /// and provide endpoint.url pointing at OpenRouter's chat completions API.
    private static func thinkSettings(
        config: DeepVoiceConfig,
        toolRegistry: ToolRegistry,
        openRouterKey: String
    ) -> [String: Any] {
        var think: [String: Any] = [
            "provider": [
                "type": "open_ai",
                "model": config.llmModel,
                "temperature": 0.7,
            ] as [String: Any],
            "endpoint": [
                "url": "https://openrouter.ai/api/v1/chat/completions",
                "headers": [
                    "Authorization": "Bearer \(openRouterKey)",
                    "HTTP-Referer": "https://github.com/thebrownproject/deepvoice",
                    "X-OpenRouter-Title": "DeepVoice",
                ],
            ] as [String: Any],
            "prompt": Prompts.system,
        ]

        let functions = toolFunctions(from: toolRegistry)
        if !functions.isEmpty {
            think["functions"] = functions
        }

        return think
    }

    // MARK: - Speak (TTS)

    private static func speakSettings(config: DeepVoiceConfig) -> [String: Any] {
        [
            "provider": [
                "type": config.ttsProvider,
                "model": config.voice,
            ],
        ]
    }

    // MARK: - Tool conversion

    /// Convert ToolRegistry definitions to Voice Agent function format.
    /// Voice Agent expects: [{ name, description, parameters }] -- no `type`/`function` wrapper.
    /// All functions are client-side (no `endpoint`), so the agent sends FunctionCallRequest
    /// and we respond with FunctionCallResponse after local execution.
    private static func toolFunctions(from registry: ToolRegistry) -> [[String: Any]] {
        registry.toolDefinitions().compactMap { def -> [String: Any]? in
            guard let params = def.function.parameters.toAny() else { return nil }
            return [
                "name": def.function.name,
                "description": def.function.description,
                "parameters": params,
            ]
        }
    }
}

// MARK: - JSONValue -> Any conversion

extension JSONValue {
    /// Convert to Foundation types (`[String: Any]`, `[Any]`, `String`, etc.)
    /// for use with `JSONSerialization`-based APIs like `sendSettings`.
    func toAny() -> Any? {
        switch self {
        case .null: return nil
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let arr): return arr.compactMap { $0.toAny() }
        case .object(let obj):
            var dict: [String: Any] = [:]
            for (k, v) in obj {
                if let val = v.toAny() {
                    dict[k] = val
                }
            }
            return dict
        }
    }
}
