import Foundation

struct DeepVoiceConfig: Codable {
    var sttProvider: String
    var ttsProvider: String
    var llmProvider: String
    var llmModel: String
    var voice: String
    var safeMode: Bool
    var confirmDestructive: Bool

    enum CodingKeys: String, CodingKey {
        case sttProvider = "stt_provider"
        case ttsProvider = "tts_provider"
        case llmProvider = "llm_provider"
        case llmModel = "llm_model"
        case voice
        case safeMode = "safe_mode"
        case confirmDestructive = "confirm_destructive"
    }

    static let defaults = DeepVoiceConfig(
        sttProvider: "deepgram",
        ttsProvider: "deepgram",
        llmProvider: "openrouter",
        llmModel: "anthropic/claude-sonnet-4",
        voice: "aura-asteria-en",
        safeMode: true,
        confirmDestructive: true
    )

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
    }
}
