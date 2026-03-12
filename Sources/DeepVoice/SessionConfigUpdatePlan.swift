import Foundation

struct SessionConfigUpdatePlan: Equatable {
    let requiresReconnect: Bool
    let updateThink: Bool
    let updateSpeak: Bool

    static let none = SessionConfigUpdatePlan(
        requiresReconnect: false,
        updateThink: false,
        updateSpeak: false
    )

    static let reconnect = SessionConfigUpdatePlan(
        requiresReconnect: true,
        updateThink: false,
        updateSpeak: false
    )

    var needsLiveAgentUpdate: Bool {
        updateThink || updateSpeak
    }
}

extension DeepVoiceConfig {
    func sessionUpdatePlan(comparedTo previous: DeepVoiceConfig) -> SessionConfigUpdatePlan {
        if sttProvider != previous.sttProvider || sttModel != previous.sttModel {
            return .reconnect
        }

        let updateThink =
            llmProvider != previous.llmProvider ||
            llmModel != previous.llmModel ||
            safeMode != previous.safeMode

        let updateSpeak =
            ttsProvider != previous.ttsProvider ||
            voice != previous.voice

        guard updateThink || updateSpeak else {
            return .none
        }

        return SessionConfigUpdatePlan(
            requiresReconnect: false,
            updateThink: updateThink,
            updateSpeak: updateSpeak
        )
    }
}
