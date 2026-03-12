# DeepVoice

Voice-first AI desktop companion for macOS. Pure Swift, single WebSocket to Deepgram Voice Agent API, BYO LLM via OpenRouter, client-side tool execution.

This file is the short agent/operator handoff. For more detail:

- current runtime: `docs/current-architecture.md`
- verified state and next steps: `docs/verification-and-next-steps.md`
- README: `README.md`

## Current Status

As of March 12, 2026:

- hosted macOS CI is green on branch `codex/macos-ci-verify`
- `swift build` and `swift test --parallel` pass on GitHub-hosted macOS
- local `swift` / `xcodebuild` were not available in the development environment used for this pass
- real end-to-end runtime validation still needs an actual Mac session

## Architecture

```text
Swift macOS App
    -> VoiceAgentRuntime
    -> AudioManager capture engine
    -> DeepgramAgentClient websocket
    -> Deepgram Voice Agent API
       - STT: Deepgram Flux (`flux-general-en` by default)
       - LLM: BYO via OpenRouter (`anthropic/claude-sonnet-4` by default)
       - TTS: Deepgram Aura-2 (`aura-2-asteria-en` by default)
    -> AudioManager playback engine
```

Core transport:

- WebSocket: `wss://agent.deepgram.com/v1/agent/converse`
- binary frames: PCM16 24kHz mono audio
- text frames: Voice Agent JSON messages

## Runtime Model

- `VoiceAgentRuntime.swift` owns the live session state
- `AppDelegate` is intentionally thin
- the Deepgram socket is kept warm between turns
- Talk starts/stops local mic capture, not the socket
- interrupt is primarily local playback suppression
- compatible settings changes use live `UpdateThink` / `UpdateSpeak`
- STT changes still reconnect the warm session

## Build

```bash
swift build
swift run
```

Requires macOS 14+ with Xcode command line tools.

## CI

Workflow:

- `.github/workflows/macos-ci.yml`
- runner: `macos-14`
- commands:
  - `swift build`
  - `swift test --parallel`

Recent successful hosted macOS runs from this pass:

- `22981896135`
- `22982058465`
- `22982113510`

## API Keys

Set via Settings UI (`Option+Shift+S`), stored in macOS Keychain (`com.thebrownproject.deepvoice`):

| Key | Account | Used For |
|-----|---------|----------|
| Deepgram | `deepgramAPIKey` | Voice Agent API (STT + TTS orchestration) |
| OpenRouter | `openRouterAPIKey` | BYO LLM |
| OpenAI | `openAIAPIKey` | `reason_deeply`, `web_search`, `capture_display` |

## Voice Agent Protocol

### Client -> Server

| Message | Purpose |
|---------|---------|
| `Settings` | Initial config after connection |
| binary frames | PCM16 24kHz mono mic audio |
| `FunctionCallResponse` | Client-side tool result |
| `KeepAlive` | Sent only while idle; scheduled from last outbound activity |
| `UpdateSpeak` | Live voice / speak config update |
| `UpdateThink` | Live think / tool-shape update |
| `UpdatePrompt` | Prompt append/update |
| `InjectUserMessage` / `InjectAgentMessage` | Inject text messages |

### Server -> Client

| Message | Purpose |
|---------|---------|
| `Welcome` | Connection established |
| `SettingsApplied` | Ready for audio |
| `ConversationText` | Transcript events |
| `AgentThinking` | LLM processing started |
| `AgentStartedSpeaking` | Response starting, includes latency metrics |
| binary frames | PCM16 24kHz mono TTS audio |
| `AgentAudioDone` | Audio complete for the turn |
| `FunctionCallRequest` | Tool call request |
| `UserStartedSpeaking` | Barge-in detected |
| `Error` / `Warning` | Protocol/runtime issues |

## Tools

All tools are client-side.

| Tool | File | Approval | Notes |
|------|------|----------|-------|
| `safe_bash` | `ShellTools.swift` | If `safeMode` or `confirmDestructive` | Allowlist + metachar rejection + incremental output draining |
| `applescript` | `ShellTools.swift` | If `safeMode` or `confirmDestructive` | `osascript` execution |
| `file_read` | `FileTools.swift` | No | 1MB limit, home dir only |
| `file_write` | `FileTools.swift` | Hidden in `safeMode`, otherwise if `confirmDestructive` | Auto-creates parent dirs |
| `frontmost_app_context` | `DesktopTools.swift` | No | Accessibility API |
| `capture_display` | `DesktopTools.swift` | No | Downscaled JPEG + low-detail OpenAI vision |
| `reason_deeply` | `AITools.swift` | No | Delegation path |
| `web_search` | `AITools.swift` | No | OpenAI-backed search path |

## Important Current Decisions

1. STT defaults to `flux-general-en`, not `nova-3`.
2. TTS defaults to Aura-2, not Aura-1.
3. Flux uses Deepgram STT `version: v2`; non-Flux Deepgram STT uses `version: v1`.
4. `flags.history = false`.
5. The app does not force `context_length` right now.
6. Keepalive is idle-aware and activity-relative, not a fixed repeating 10s loop.
7. `safeMode` materially changes tool exposure and approval behavior.

## Conventions

- SwiftUI + AppKit hybrid
- `@MainActor` for UI/runtime state where appropriate
- `DispatchQueue` for audio and websocket work
- `@unchecked Sendable` only where manual synchronization or queue confinement is used
- tool failures return strings to the LLM instead of crashing
- latency values from Deepgram are seconds and are converted to ms for display/logging
- all tool handlers use `(String) async throws -> String`

## Real Mac Validation Still Needed

Hosted CI is not enough for:

- microphone permission flow
- hotkeys
- real capture/playback latency
- interrupt behavior during live playback
- screen capture permissions and usefulness at current compression
- realistic Keychain behavior

## Recommended Next Step

Do the first real macOS validation before starting the larger runtime refactor for protocol seams and deeper session-state tests.
