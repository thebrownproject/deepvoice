import SwiftUI
import KeyboardShortcuts

enum DeepgramVoice: String, CaseIterable, Identifiable {
    // Aura-2 (recommended)
    case aura2LunaEn = "aura-2-luna-en"
    case aura2CoraEn = "aura-2-cora-en"
    case aura2HelenaEn = "aura-2-helena-en"
    case aura2CordeliaEn = "aura-2-cordelia-en"
    case aura2AsteriaEn = "aura-2-asteria-en"
    case aura2AndromedaEn = "aura-2-andromeda-en"
    case aura2ThaliaEn = "aura-2-thalia-en"
    case aura2AthenaEn = "aura-2-athena-en"
    case aura2OrionEn = "aura-2-orion-en"
    case aura2OrpheusEn = "aura-2-orpheus-en"
    case aura2ApolloEn = "aura-2-apollo-en"
    case aura2VestaEn = "aura-2-vesta-en"
    case aura2ArcasEn = "aura-2-arcas-en"
    case aura2AriesEn = "aura-2-aries-en"
    case aura2ZeusEn = "aura-2-zeus-en"
    // Aura-1 (legacy)
    case auraAsteriaEn = "aura-asteria-en"
    case auraLunaEn = "aura-luna-en"
    case auraOrionEn = "aura-orion-en"

    var id: String { rawValue }

    var displayName: String {
        rawValue
            .replacingOccurrences(of: "aura-2-", with: "v2 ")
            .replacingOccurrences(of: "aura-", with: "v1 ")
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

            Section("Audio") {
                Picker("Route mode", selection: $store.config.audioRouteMode) {
                    ForEach(AudioRouteMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Text(store.config.audioRouteMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(width: 440, height: 620)
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
            HStack(spacing: 6) {
                SecureField("", text: $value, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($isFocused)
                    .onSubmit { persist() }
                    .onChange(of: isFocused) { wasFocused, isFocused in
                        if wasFocused && !isFocused { persist() }
                    }
                if !value.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Key configured")
                }
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
