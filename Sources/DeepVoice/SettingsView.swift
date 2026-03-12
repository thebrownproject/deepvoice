import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @State private var deepgramKey = ""
    @State private var openRouterKey = ""
    @State private var openAIKey = ""

    @State private var config = DeepVoiceConfig.defaults
    @State private var voiceDraft = DeepVoiceConfig.defaults.voice
    @State private var llmModelDraft = DeepVoiceConfig.defaults.llmModel
    @State private var sttModelDraft = DeepVoiceConfig.defaults.sttModel
    @State private var hasLoadedConfig = false

    @AppStorage(transcriptVisibilityKey) private var transcriptVisible = false

    var body: some View {
        Form {
            apiKeysSection
            voiceSection
            modelSection
            hotkeySection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
        .onAppear {
            loadKeys()
            loadConfig()
            hasLoadedConfig = true
        }
        .onChange(of: config.safeMode) { _, _ in
            guard hasLoadedConfig else { return }
            persistConfig()
        }
        .onChange(of: config.confirmDestructive) { _, _ in
            guard hasLoadedConfig else { return }
            persistConfig()
        }
    }

    private var apiKeysSection: some View {
        Section("API Keys") {
            KeyField(
                label: "Deepgram",
                placeholder: "dg-...",
                value: $deepgramKey,
                account: .deepgramAPIKey
            )
            KeyField(
                label: "OpenRouter",
                placeholder: "sk-or-...",
                value: $openRouterKey,
                account: .openRouterAPIKey
            )
            VStack(alignment: .leading, spacing: 4) {
                KeyField(
                    label: "OpenAI",
                    placeholder: "sk-...",
                    value: $openAIKey,
                    account: .openAIAPIKey
                )
                Text("Used for vision and delegation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Stored securely in macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var voiceSection: some View {
        Section("Voice") {
            LabeledContent("Voice model") {
                ConfigField(
                    placeholder: DeepVoiceConfig.defaults.voice,
                    value: $voiceDraft,
                    onCommit: persistConfig
                )
            }
            Text("Use a Deepgram Voice Agent TTS model, for example aura-2-asteria-en.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelSection: some View {
        Section("Models") {
            LabeledContent("LLM") {
                ConfigField(
                    placeholder: DeepVoiceConfig.defaults.llmModel,
                    value: $llmModelDraft,
                    onCommit: persistConfig
                )
            }
            LabeledContent("STT") {
                ConfigField(
                    placeholder: DeepVoiceConfig.defaults.sttModel,
                    value: $sttModelDraft,
                    onCommit: persistConfig
                )
            }
            Text("flux-general-en is the current low-latency default for listening.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hotkeySection: some View {
        Section("Hotkeys") {
            HStack {
                Text("Activate")
                Spacer()
                KeyboardShortcuts.Recorder("", name: .toggleListening)
            }
            HStack {
                Text("Open Settings")
                Spacer()
                KeyboardShortcuts.Recorder("", name: .openSettings)
            }
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Safe mode", isOn: $config.safeMode)
            Text("Keep shell use on the allowlist, require approval for shell and AppleScript tools, and hide write tools.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Confirm destructive actions", isOn: $config.confirmDestructive)

            Toggle("Show transcript", isOn: $transcriptVisible)
            Text("Display live transcript in the console.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loadKeys() {
        deepgramKey = KeychainHelper.loadAPIKey(for: .deepgramAPIKey) ?? ""
        openRouterKey = KeychainHelper.loadAPIKey(for: .openRouterAPIKey) ?? ""
        openAIKey = KeychainHelper.loadAPIKey(for: .openAIAPIKey) ?? ""
    }

    private func loadConfig() {
        config = (try? DeepVoiceConfig.load()) ?? .defaults
        syncDrafts()
    }

    private func persistConfig() {
        config.voice = normalized(voiceDraft, fallback: DeepVoiceConfig.defaults.voice)
        config.llmModel = normalized(llmModelDraft, fallback: DeepVoiceConfig.defaults.llmModel)
        config.sttModel = normalized(sttModelDraft, fallback: DeepVoiceConfig.defaults.sttModel)

        do {
            try config.save()
            syncDrafts()
        } catch {
            syncDrafts()
        }
    }

    private func syncDrafts() {
        voiceDraft = config.voice
        llmModelDraft = config.llmModel
        sttModelDraft = config.sttModel
    }

    private func normalized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

private struct ConfigField: View {
    let placeholder: String
    @Binding var value: String
    let onCommit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $value, prompt: Text(placeholder))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .focused($isFocused)
            .onSubmit { commit() }
            .onChange(of: isFocused) { wasFocused, isFocused in
                if wasFocused && !isFocused {
                    commit()
                }
            }
    }

    private func commit() {
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        onCommit()
    }
}

private struct KeyField: View {
    let label: String
    let placeholder: String
    @Binding var value: String
    let account: KeychainAccount
    @FocusState private var isFocused: Bool

    var body: some View {
        LabeledContent(label) {
            SecureField("", text: $value, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($isFocused)
                .onSubmit { persist() }
                .onChange(of: isFocused) { wasFocused, isFocused in
                    if wasFocused && !isFocused { persist() }
                }
        }
    }

    private func persist() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.deleteAPIKey(for: account)
        } else {
            KeychainHelper.saveAPIKey(trimmed, for: account)
        }
        value = trimmed
    }
}
