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
    @State private var deepgramKey = ""
    @State private var openRouterKey = ""
    @State private var openAIKey = ""

    @AppStorage("selectedVoice") private var selectedVoice = DeepgramVoice.auraAsteriaEn.rawValue
    @AppStorage("llmModel") private var llmModel = "anthropic/claude-sonnet-4-20250514"
    @AppStorage("sttModel") private var sttModel = "nova-3"
    @AppStorage("safeModeEnabled") private var safeModeEnabled = true
    @AppStorage("confirmDestructive") private var confirmDestructive = true
    @AppStorage(TranscriptStore.visibilityKey) private var transcriptVisible = false

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
        .onAppear { loadKeys() }
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
                Text("Used for vision and delegation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Stored securely in macOS Keychain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var voiceSection: some View {
        Section("Voice") {
            Picker("Voice", selection: $selectedVoice) {
                ForEach(DeepgramVoice.allCases) { voice in
                    Text(voice.displayName).tag(voice.rawValue)
                }
            }
        }
    }

    private var modelSection: some View {
        Section("Models") {
            LabeledContent("LLM") {
                TextField("", text: $llmModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            LabeledContent("STT") {
                TextField("", text: $sttModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
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
            Toggle("Safe mode", isOn: $safeModeEnabled)
            Text("Restrict shell commands to a safe allowlist and disable write tools.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Confirm destructive actions", isOn: $confirmDestructive)

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
