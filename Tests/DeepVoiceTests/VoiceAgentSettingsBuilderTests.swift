import XCTest
@testable import DeepVoice

final class VoiceAgentSettingsBuilderTests: XCTestCase {
    func testBuilderUsesFluxDefaultsAndLatencyFriendlyFlags() throws {
        let registry = ToolRegistry.withDefaultTools(config: .defaults)
        let settings = VoiceAgentSettingsBuilder.build(
            config: .defaults,
            toolRegistry: registry,
            openRouterKey: "test-openrouter-key"
        )

        let flags = try requireDictionary(settings["flags"])
        XCTAssertEqual(flags["history"] as? Bool, false)

        let agent = try requireDictionary(settings["agent"])
        let listen = try requireDictionary(agent["listen"])
        let listenProvider = try requireDictionary(listen["provider"])
        XCTAssertEqual(listenProvider["model"] as? String, DeepVoiceConfig.defaults.sttModel)
        XCTAssertNil(listenProvider["smart_format"], "Flux models should not set smart_format")

        let think = try requireDictionary(agent["think"])
        XCTAssertEqual(think["context_length"] as? Int, 12000)

        let endpoint = try requireDictionary(think["endpoint"])
        let headers = try requireDictionary(endpoint["headers"])
        XCTAssertEqual(headers["X-OpenRouter-Title"] as? String, "DeepVoice")

        let speak = try requireDictionary(agent["speak"])
        let speakProvider = try requireDictionary(speak["provider"])
        XCTAssertEqual(speakProvider["model"] as? String, DeepVoiceConfig.defaults.voice)
    }

    func testBuilderEnablesSmartFormatForNonFluxModels() throws {
        var config = DeepVoiceConfig.defaults
        config.sttModel = "nova-3"

        let registry = ToolRegistry.withDefaultTools(config: config)
        let settings = VoiceAgentSettingsBuilder.build(
            config: config,
            toolRegistry: registry,
            openRouterKey: "test-openrouter-key"
        )

        let agent = try requireDictionary(settings["agent"])
        let listen = try requireDictionary(agent["listen"])
        let listenProvider = try requireDictionary(listen["provider"])

        XCTAssertEqual(listenProvider["model"] as? String, "nova-3")
        XCTAssertEqual(listenProvider["smart_format"] as? Bool, true)
    }

    private func requireDictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }
}
