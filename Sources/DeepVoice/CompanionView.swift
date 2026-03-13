import SwiftUI

struct CompanionView: View {
    var state: DevConsoleState
    var actions: DevConsoleActions

    private let warmWhite = Color(red: 0.92, green: 0.88, blue: 0.84)

    /// The most recent assistant message.
    private var latestAssistantEntry: TranscriptEntry? {
        state.transcriptEntries.last(where: { !$0.isUser })
    }

    /// Derived directly from observable state -- onChange doesn't fire in NSHostingView.
    private var textVisible: Bool {
        switch state.appState {
        case .speaking: true
        case .listening, .idle, .error: latestAssistantEntry != nil
        case .thinking: false
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Controls centered above the orb
            controlBar

            // Orb -- floating raw
            PresenceView(appState: state.appState, captureEnergy: state.captureEnergy, playbackEnergy: state.playbackEnergy)
                .frame(width: 220, height: 220)

            // Text in its own glass capsule
            consciousText
                .frame(maxWidth: 260)
        }
        .frame(width: 280, height: 380)
    }

    // MARK: - Conscious Text

    @ViewBuilder
    private var consciousText: some View {
        if let entry = latestAssistantEntry {
            Text(entry.text)
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(warmWhite)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(GlassCapsuleModifier(cornerRadius: 14))
                .animation(.easeInOut(duration: 0.4), value: entry.text)
                .opacity(textVisible ? 1.0 : 0)
                .offset(y: textVisible ? 0 : 4)
                .animation(.easeInOut(duration: 1.0), value: textVisible)
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 12) {
            talkButton
            stopButton
            settingsButton
        }
    }

    @ViewBuilder
    private var talkButton: some View {
        let icon = state.appState == .listening ? "waveform" : "mic.fill"

        if #available(macOS 26.0, *) {
            Button(action: actions.onTalkToggle) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.blue), in: .circle)
        } else {
            Button(action: actions.onTalkToggle) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.blue, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var stopButton: some View {
        if #available(macOS 26.0, *) {
            Button(action: actions.onInterrupt) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .circle)
            .disabled(state.appState == .idle)
            .opacity(state.appState == .idle ? 0.3 : 1.0)
        } else {
            Button(action: actions.onInterrupt) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(state.appState == .idle)
            .opacity(state.appState == .idle ? 0.3 : 1.0)
        }
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 26.0, *) {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 14))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .circle)
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 14))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

}

/// Applies liquid glass on macOS 26+, falls back to thin material.
private struct GlassCapsuleModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

#Preview {
    CompanionView(state: DevConsoleState(), actions: DevConsoleActions())
        .environment(ConfigStore())
}
