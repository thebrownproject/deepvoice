import XCTest
@testable import DeepVoice

final class SessionConfigUpdatePlanTests: XCTestCase {
    func testVoiceChangeUsesLiveSpeakUpdate() {
        var updated = DeepVoiceConfig.defaults
        updated.voice = "aura-2-thalia-en"

        let plan = updated.sessionUpdatePlan(comparedTo: .defaults)

        XCTAssertEqual(
            plan,
            SessionConfigUpdatePlan(
                requiresReconnect: false,
                updateThink: false,
                updateSpeak: true
            )
        )
    }

    func testLLMAndSafeModeChangesUseLiveThinkUpdate() {
        var updated = DeepVoiceConfig.defaults
        updated.llmModel = "openai/gpt-5-mini"
        updated.safeMode = false

        let plan = updated.sessionUpdatePlan(comparedTo: .defaults)

        XCTAssertEqual(
            plan,
            SessionConfigUpdatePlan(
                requiresReconnect: false,
                updateThink: true,
                updateSpeak: false
            )
        )
    }

    func testConfirmDestructiveChangeDoesNotTouchWarmSession() {
        var updated = DeepVoiceConfig.defaults
        updated.confirmDestructive.toggle()

        XCTAssertEqual(updated.sessionUpdatePlan(comparedTo: .defaults), .none)
    }

    func testSTTChangeStillReconnects() {
        var updated = DeepVoiceConfig.defaults
        updated.sttModel = "nova-3"
        updated.voice = "aura-2-thalia-en"

        XCTAssertEqual(updated.sessionUpdatePlan(comparedTo: .defaults), .reconnect)
    }
}
