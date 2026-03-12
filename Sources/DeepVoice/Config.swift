import Foundation

extension Notification.Name {
    static let deepVoiceConfigDidChange = Notification.Name("DeepVoiceConfigDidChange")
    static let deepVoiceAPIKeysDidChange = Notification.Name("DeepVoiceAPIKeysDidChange")
}

struct DeepVoiceConfig: Codable, Equatable {
    var sttProvider: String
    var sttModel: String
    var ttsProvider: String
    var llmProvider: String
    var llmModel: String
    var voice: String
    var safeMode: Bool
    var confirmDestructive: Bool

    enum CodingKeys: String, CodingKey {
        case sttProvider = "stt_provider"
        case sttModel = "stt_model"
        case ttsProvider = "tts_provider"
        case llmProvider = "llm_provider"
        case llmModel = "llm_model"
        case voice
        case safeMode = "safe_mode"
        case confirmDestructive = "confirm_destructive"
    }

    static let defaults = DeepVoiceConfig(
        sttProvider: "deepgram",
        sttModel: "flux-general-en",
        ttsProvider: "deepgram",
        llmProvider: "openrouter",
        llmModel: "anthropic/claude-sonnet-4",
        voice: "aura-2-asteria-en",
        safeMode: true,
        confirmDestructive: true
    )

    init(
        sttProvider: String,
        sttModel: String,
        ttsProvider: String,
        llmProvider: String,
        llmModel: String,
        voice: String,
        safeMode: Bool,
        confirmDestructive: Bool
    ) {
        self.sttProvider = sttProvider
        self.sttModel = sttModel
        self.ttsProvider = ttsProvider
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.voice = voice
        self.safeMode = safeMode
        self.confirmDestructive = confirmDestructive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults

        sttProvider = try container.decodeIfPresent(String.self, forKey: .sttProvider) ?? defaults.sttProvider
        sttModel = try container.decodeIfPresent(String.self, forKey: .sttModel) ?? defaults.sttModel
        ttsProvider = try container.decodeIfPresent(String.self, forKey: .ttsProvider) ?? defaults.ttsProvider
        llmProvider = try container.decodeIfPresent(String.self, forKey: .llmProvider) ?? defaults.llmProvider
        llmModel = try container.decodeIfPresent(String.self, forKey: .llmModel) ?? defaults.llmModel
        voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? defaults.voice
        safeMode = try container.decodeIfPresent(Bool.self, forKey: .safeMode) ?? defaults.safeMode
        confirmDestructive = try container.decodeIfPresent(Bool.self, forKey: .confirmDestructive) ?? defaults.confirmDestructive
    }

    static var dataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".deepvoice")
    }

    static var configPath: URL {
        dataDir.appendingPathComponent("config.json")
    }

    static func bootstrapStorage() {
        let fm = FileManager.default
        let dirs = [dataDir, dataDir.appendingPathComponent("daily")]
        for dir in dirs {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let profile = dataDir.appendingPathComponent("profile.md")
        if !fm.fileExists(atPath: profile.path) {
            fm.createFile(atPath: profile.path, contents: nil)
        }
        let prefs = dataDir.appendingPathComponent("preferences.md")
        if !fm.fileExists(atPath: prefs.path) {
            fm.createFile(atPath: prefs.path, contents: nil)
        }
    }

    static func load() throws -> DeepVoiceConfig {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath.path) else { return defaults }
        let data = try Data(contentsOf: configPath)
        let decoder = JSONDecoder()
        return try decoder.decode(DeepVoiceConfig.self, from: data)
    }

    func save() throws {
        DeepVoiceConfig.bootstrapStorage()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: DeepVoiceConfig.configPath)
        NotificationCenter.default.post(name: .deepVoiceConfigDidChange, object: nil)
    }
}
