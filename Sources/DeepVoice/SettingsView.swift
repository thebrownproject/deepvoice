import SwiftUI
import KeyboardShortcuts

enum DeepgramVoice: String, CaseIterable, Identifiable {
    case auraAsteriaEn = "aura-asteria-en"
    case auraLunaEn = "aura-luna-en"
    case auraStellaEn = "aura-stella-en"
    case auraAthenaEn = "aura-athena-en"
    case auraHeraEn = "aura-hera-en"
    case auraOrionEn = "aura-orion-en"
    case auraArcasEn = "aura-arcas-en"
    case auraPerseusEn = "aura-perseus-en"
    case auraAngusEn = "aura-angus-en"
    case auraOrpheusEn = "aura-orpheus-en"
    case auraHeliosEn = "aura-helios-en"
    case auraZeusEn = "aura-zeus-en"

    var id: String { rawValue }

    var displayName: String {
        rawValue
            .replacingOccurrences(of: "aura-", with: "")
            .replacingOccurrences(of: "-en", with: "")
            .capitalized
    }
}

struct SettingsView: View {
    @Environment(ConfigStore.self) private var configStore
    @State private var deepgramKey = ""
    @State private var openRouterKey = ""
    @State private var openAIKey = ""

    var body: some View {
        @Bindable var store = configStore
        Form {
            // API Keys
            Section("API Keys") {
                KeyField(
                    label: "Deepgram",
                    placeholder: "dg-...",
                    value: $deepgramKey,
                    account: .deepgramAPIKey,
                    onSave: { configStore.reloadAPIKeys() }
                )
                KeyField(
                    label: "OpenRouter",
                    placeholder: "sk-or-...",
                    value: $openRouterKey,
                    account: .openRouterAPIKey,
                    onSave: { configStore.reloadAPIKeys() }
                )
                VStack(alignment: .leading, spacing: 4) {
                    KeyField(
                        label: "OpenAI",
                        placeholder: "sk-...",
                        value: $openAIKey,
                        account: .openAIAPIKey,
                        onSave: { configStore.reloadAPIKeys() }
                    )
                    Text("Used for vision and delegation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Stored securely in macOS Keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Voice
            Section("Voice") {
                Picker("Voice", selection: $store.config.voice) {
                    ForEach(DeepgramVoice.allCases) { voice in
                        Text(voice.displayName).tag(voice.rawValue)
                    }
                }
            }

            // Models
            Section("Models") {
                LabeledContent("LLM") {
                    TextField("", text: $store.config.llmModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }

            // Hotkeys
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

            // General
            Section("General") {
                Toggle("Safe mode", isOn: $store.config.safeMode)
                Text("Restrict shell commands to a safe allowlist and disable write tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Confirm destructive actions", isOn: $store.config.confirmDestructive)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
        .onAppear { loadKeys() }
    }

    private func loadKeys() {
        deepgramKey = KeychainHelper.loadAPIKey(for: .deepgramAPIKey) ?? ""
        openRouterKey = KeychainHelper.loadAPIKey(for: .openRouterAPIKey) ?? ""
        openAIKey = KeychainHelper.loadAPIKey(for: .openAIAPIKey) ?? ""
    }
}

private struct KeyField: View {
    let label: String
    let placeholder: String
    @Binding var value: String
    let account: KeychainAccount
    var onSave: () -> Void = {}
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
        onSave()
    }
}
