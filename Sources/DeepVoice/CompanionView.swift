import SwiftUI

struct CompanionView: View {
    var state: DevConsoleState
    var actions: DevConsoleActions

    /// Warm near-black background
    private let bgColor = Color(red: 0.06, green: 0.05, blue: 0.07)
    private let warmWhite = Color(red: 0.92, green: 0.88, blue: 0.84)
    private let mutedSecondary = Color(white: 0.5)

    /// Last few transcript entries for display
    private var recentEntries: [TranscriptEntry] {
        Array(state.transcriptEntries.suffix(3))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            // Presence ring
            PresenceView(appState: state.appState, energy: max(state.captureEnergy, state.playbackEnergy))
                .frame(width: 250, height: 250)

            Spacer(minLength: 20)

            // Transcript area
            transcriptSection
                .frame(maxWidth: .infinity, minHeight: 100)
                .padding(.horizontal, 32)

            Spacer(minLength: 16)

            // Control bar
            controlBar
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(width: 400, height: 520)
        .background(bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        let lastAssistantIndex = recentEntries.lastIndex(where: { !$0.isUser })
        return VStack(alignment: .center, spacing: 8) {
            ForEach(Array(recentEntries.enumerated()), id: \.element.id) { index, entry in
                let isLatestAssistant = index == lastAssistantIndex && !entry.isUser
                let age = recentEntries.count - 1 - index
                let fadeOpacity = age == 0 ? 1.0 : max(0.3, 1.0 - Double(age) * 0.3)

                Group {
                    if isLatestAssistant {
                        TypewriterText(text: entry.text, isFinal: entry.isFinal)
                    } else {
                        Text(entry.text)
                    }
                }
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundStyle(entry.isUser ? mutedSecondary : warmWhite)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .opacity(fadeOpacity * (entry.isFinal ? 1.0 : 0.6))
                .transition(.opacity.animation(.easeIn(duration: 0.3)))
                .id(entry.id)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: recentEntries.map(\.id))
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 16) {
            // Talk button
            Button(action: actions.onTalkToggle) {
                Text(talkLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(bgColor)
                    .frame(minWidth: 140, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(warmWhite.opacity(0.85))
            .controlSize(.regular)

            // Stop button
            Button(action: actions.onInterrupt) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(mutedSecondary)
            }
            .buttonStyle(.plain)
            .disabled(state.appState == .idle)
            .opacity(state.appState == .idle ? 0.3 : 1.0)

            Spacer()

            // Settings gear
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 14))
                    .foregroundStyle(mutedSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var talkLabel: String {
        switch state.appState {
        case .listening: "Listening..."
        default: "Talk (Opt+S)"
        }
    }
}

// Reveals text character-by-character, restarting the reveal when new text arrives
private struct TypewriterText: View {
    let text: String
    let isFinal: Bool

    @State private var revealedCount = 0
    @State private var timer: Timer?
    // Track the text we've already fully revealed so new chunks animate from where we left off
    @State private var baseLength = 0

    private static let charInterval: TimeInterval = 0.035

    var body: some View {
        let visible = String(text.prefix(revealedCount))
        Text(visible)
            .onChange(of: text) { oldValue, newValue in
                startRevealing(from: oldValue, to: newValue)
            }
            .onAppear {
                revealedCount = 0
                baseLength = 0
                startTimer()
            }
            .onDisappear { stopTimer() }
    }

    private func startRevealing(from oldText: String, to newText: String) {
        // When text updates mid-stream, keep already-revealed chars and animate only new ones
        baseLength = min(revealedCount, newText.count)
        revealedCount = baseLength
        startTimer()
    }

    private func startTimer() {
        stopTimer()
        guard revealedCount < text.count else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.charInterval, repeats: true) { _ in
            Task { @MainActor in
                guard revealedCount < text.count else {
                    stopTimer()
                    return
                }
                revealedCount += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

#Preview {
    CompanionView(state: DevConsoleState(), actions: DevConsoleActions())
        .environment(ConfigStore())
}
