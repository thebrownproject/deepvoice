import Foundation
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "Config")

struct DeepVoiceConfig: Codable, Equatable {
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

// MARK: - Observable config store shared between Settings UI and AppDelegate

@Observable @MainActor
final class ConfigStore {
    var config: DeepVoiceConfig {
        didSet {
            guard config != oldValue else { return }
            scheduleSave()
        }
    }

    /// Cached API keys -- reloaded on demand via `reloadAPIKeys()`.
    private(set) var deepgramAPIKey: String?
    private(set) var openRouterAPIKey: String?
    private(set) var openAIAPIKey: String?

    private var saveTask: Task<Void, Never>?

    init() {
        config = (try? DeepVoiceConfig.load()) ?? .defaults
        reloadAPIKeys()
    }

    func reloadAPIKeys() {
        deepgramAPIKey = KeychainHelper.loadAPIKey(for: .deepgramAPIKey)
        openRouterAPIKey = KeychainHelper.loadAPIKey(for: .openRouterAPIKey)
        openAIAPIKey = KeychainHelper.loadAPIKey(for: .openAIAPIKey)
    }

    /// Debounce config saves so typing in text fields doesn't write to disk per keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s debounce
            guard !Task.isCancelled, let self else { return }
            do {
                try self.config.save()
                log.info("Config saved")
            } catch {
                log.error("Config save failed: \(error.localizedDescription)")
            }
        }
    }
}

