import SwiftUI

struct CompanionView: View {
    var state: DevConsoleState
    var actions: DevConsoleActions

    private let warmWhite = Color(red: 0.92, green: 0.88, blue: 0.84)

    @State private var isHovering = false
    @State private var showControls = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var textDismissTask: Task<Void, Never>?
    @State private var textDismissed = false
    @State private var trackedEntryId: UUID?
    @State private var wasPlaying = false

    /// The most recent assistant message.
    private var latestAssistantEntry: TranscriptEntry? {
        state.transcriptEntries.last(where: { !$0.isUser })
    }

    /// Whether the orb is in an active session (not idle).
    private var isActive: Bool {
        state.appState != .idle && state.appState != .error
    }

    var body: some View {
        let currentEntryId = latestAssistantEntry?.id
        let isNewEntry = currentEntryId != nil && currentEntryId != trackedEntryId

        // Show text when: hovering, or speaking/active and not yet dismissed
        let textShowing: Bool = {
            if isHovering && latestAssistantEntry != nil { return true }
            if textDismissed && !isNewEntry { return false }
            switch state.appState {
            case .speaking: return true
            case .listening, .idle, .error: return latestAssistantEntry != nil
            case .thinking: return false
            }
        }()

        // Detect when playback stops to start dismiss timer
        let currentlyPlaying = state.isPlaying

        ZStack {
            // Orb + controls pinned to center of frame
            VStack(spacing: 0) {
                // Controls -- hidden by default, pop up on hover with delay
                controlBar
                    .opacity(showControls ? 1.0 : 0)
                    .offset(y: showControls ? 0 : 10)
                    .animation(.easeOut(duration: 0.3), value: showControls)
                    .padding(.bottom, -8)
                    .zIndex(1)

            ZStack {
                // Glass core (always visible)
                if #available(macOS 26.0, *) {
                    Circle()
                        .fill(.clear)
                        .frame(width: 70, height: 70)
                        .glassEffect(.clear, in: .circle)
                } else {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 70, height: 70)
                }

                // Cloud glow on hover when idle (PresenceView core without rings)
                PresenceView(appState: state.appState, captureEnergy: state.captureEnergy, playbackEnergy: state.playbackEnergy, showRings: false)
                    .frame(width: 150, height: 150)
                    .opacity(!isActive && isHovering ? 1.0 : 0)
                    .animation(.easeInOut(duration: 0.5), value: isHovering)
                    .animation(.easeInOut(duration: 0.5), value: isActive)

                // Full rings (only when active session)
                PresenceView(appState: state.appState, captureEnergy: state.captureEnergy, playbackEnergy: state.playbackEnergy, showRings: true)
                    .frame(width: 150, height: 150)
                    .opacity(isActive ? 1.0 : 0)
                    .animation(.easeInOut(duration: 1.0), value: isActive)
            }
            .frame(width: 150, height: 150)
            .onTapGesture {
                actions.onTalkToggle()
            }
            } // end VStack (orb + controls)

            // Text anchored below orb (top edge fixed), doesn't affect orb position
            VStack {
                Spacer().frame(height: 345)
                if let entry = latestAssistantEntry {
                    Text(entry.text)
                        .font(.system(size: 13, weight: .regular, design: .default))
                        .foregroundStyle(warmWhite)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(GlassCapsuleModifier(cornerRadius: 14))
                        .frame(maxWidth: 220)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: entry.text)
                        .opacity(textShowing ? 1.0 : 0)
                        .animation(.easeInOut(duration: 0.8), value: textShowing)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 240, height: 550)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                hoverTask?.cancel()
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    showControls = true
                }
            } else {
                hoverTask?.cancel()
                showControls = false
            }
        }
        .task(id: currentEntryId) {
            guard let currentEntryId, currentEntryId != trackedEntryId else { return }
            trackedEntryId = currentEntryId
            textDismissed = false
            textDismissTask?.cancel()
        }
        .task(id: currentlyPlaying) {
            // Start 7s dismiss timer when playback stops
            if wasPlaying && !currentlyPlaying {
                textDismissTask?.cancel()
                textDismissTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 7_000_000_000)
                    guard !Task.isCancelled else { return }
                    textDismissed = true
                }
            }
            wasPlaying = currentlyPlaying
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
