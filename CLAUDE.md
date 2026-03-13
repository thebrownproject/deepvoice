# DeepVoice

A voice-first AI desktop companion for macOS. Pure Swift, single WebSocket to Deepgram Voice Agent API, BYO LLM via OpenRouter, client-side tool execution.

## Architecture

```
Swift macOS App
    |  Single WebSocket (wss://agent.deepgram.com/v1/agent/converse)
    |  - Binary frames: PCM16 24kHz mono audio (both directions)
    |  - Text frames: JSON control messages (Voice Agent protocol)
    v
Deepgram Voice Agent API (server-side orchestration)
    |-- STT: Deepgram Nova-3
    |-- LLM: BYO via OpenRouter (default: gemini-3.1-flash-lite-preview, configurable)
    |-- TTS: Deepgram Aura-2 (aura-2-vesta-en)
    |-- Function calling: client-side (FunctionCallRequest/Response)
```

## Build

```bash
swift build
swift run          # macOS only, needs mic + screen permissions
```

Requires macOS 14+ with Xcode command line tools.

## API Keys

Set via Settings UI (Option+Shift+S). Stored in macOS Keychain (`com.thebrownproject.deepvoice`) with a file-based fallback at `~/.deepvoice/keys.json` for unsigned `swift run` builds where Keychain access fails.

| Key | Account | Used For |
|-----|---------|----------|
| Deepgram | `deepgramAPIKey` | Voice Agent API (STT + TTS) |
| OpenRouter | `openRouterAPIKey` | BYO LLM (configurable, default: gemini-3.1-flash-lite-preview) |
| OpenAI | `openAIAPIKey` | reason_deeply, web_search, capture_display vision |

## Voice Agent Protocol

### Client -> Server

| Message | Purpose |
|---------|---------|
| `Settings` | Initial config (audio format, STT, LLM, TTS, tools) |
| Binary frames | PCM16 24kHz mono audio from mic |
| `FunctionCallResponse` | Tool execution result (id, name, content) |
| `KeepAlive` | Sent every 10s to maintain connection |
| `UpdateSpeak` / `UpdateThink` / `UpdatePrompt` | Runtime config updates (UpdatePrompt used for conversation history injection on reconnect) |
| `InjectUserMessage` / `InjectAgentMessage` | Inject text messages (avoid for history -- causes re-execution of tool calls) |

### Server -> Client

| Message | Purpose |
|---------|---------|
| `Welcome` | Connection established (includes request_id) |
| `SettingsApplied` | Config accepted, ready for audio |
| `ConversationText` | Transcript (role: user/assistant) |
| `AgentThinking` | LLM processing started |
| `AgentStartedSpeaking` | Audio response starting (includes latency metrics) |
| Binary frames | PCM16 24kHz mono TTS audio |
| `AgentAudioDone` | All audio sent for this turn |
| `FunctionCallRequest` | Tool call request (functions array) |
| `UserStartedSpeaking` | Barge-in detected |
| `Error` / `Warning` | Error/warning messages |

## Tools

All 8 tools execute client-side. Voice Agent sends `FunctionCallRequest`, app runs the tool locally, sends `FunctionCallResponse` back.

| Tool | File | Approval | Notes |
|------|------|----------|-------|
| `safe_bash` | ShellTools.swift | If confirmDestructive | Allowlist + metachar rejection |
| `applescript` | ShellTools.swift | If confirmDestructive | osascript execution |
| `file_read` | FileTools.swift | No | 1MB limit, home dir only |
| `file_write` | FileTools.swift | If confirmDestructive | Auto-creates parent dirs |
| `frontmost_app_context` | DesktopTools.swift | No | macOS Accessibility API |
| `capture_display` | DesktopTools.swift | No | Screen capture + OpenAI vision |
| `reason_deeply` | AITools.swift | No | gpt-5-mini delegation, 2 retries (requires OpenAI key) |
| `web_search` | AITools.swift | No | OpenAI Responses API (requires OpenAI key) |

## Key Design Decisions

1. **Single WebSocket to Deepgram Voice Agent** -- server handles STT+LLM+TTS orchestration, client just sends/receives audio and handles function calls
2. **BYO LLM via OpenRouter** -- `provider.type = "open_ai"` with custom `endpoint` pointing at OpenRouter's OpenAI-compatible API
3. **Client-side function calling** -- all tools run locally on the Mac, results sent back through the WebSocket
4. **Shell metacharacter blocking** -- safe_bash rejects `;|&\`$(){}\\!<>\n\r` before allowlist check to prevent injection
5. **Approval flow via async continuations** -- FunctionCallHandler suspends, AppDelegate shows UI, continuation resumes on approve/reject. `confirmDestructive` is off by default.
6. **Tool name aliasing** -- LLMs often call "bash" instead of "safe_bash". Three-layer fix: (1) system prompt explicitly names tools, (2) "bash" registered as alias in Deepgram tool list, (3) client-side alias mapping in FunctionCallHandler resolves bash/shell/run_bash to safe_bash
7. **Separate audio engines** -- Capture and playback use independent AVAudioEngine instances to prevent Bluetooth HFP mode switch. `Clear Output` uses HAL capture on non-Bluetooth mic. `AirPods Mic` uses VoiceProcessingIO at 44.1kHz with conversion to 24kHz.
8. **ConfigStore as single source of truth** -- `@Observable` ConfigStore shared via SwiftUI `.environment()`. Settings UI binds directly to it. Config changes propagate live to ToolRegistry via `withObservationTracking`.
9. **Safe mode blocks destructive tools at execute time** -- When enabled, `ToolRegistry.execute()` rejects destructive tools before running the handler. Off by default.
10. **Conversation history via UpdatePrompt** -- On WebSocket reconnect, transcript history is injected into the system prompt via `UpdatePrompt`. Using `InjectUserMessage`/`InjectAgentMessage` causes the agent to re-execute old tool calls. History only persists within the app session (not across restarts).
11. **Voice-first output formatting** -- System prompt instructs the LLM to never use markdown, backticks, asterisks, or bullet points since all output is spoken via TTS.
12. **File-based API key fallback** -- Keychain access fails for unsigned `swift run` builds. `KeychainHelper` falls back to `~/.deepvoice/keys.json` (chmod 600, gitignored).
13. **Dual-window UI** -- CompanionPanel (floating orb) at `.statusBar` level for always-visible speech control, DevConsoleView (main) for development/debugging. Both share the same `DevConsoleState` and `DevConsoleActions`. CompanionPanel uses `FirstMouseHostingView` (overrides `acceptsFirstMouse`) for click-through when unfocused.
14. **PresenceView showRings parameter** -- Single Canvas-based animated rings component supports "core glow only" (`showRings: false`) for idle hover cloud effect and "full rings" (`showRings: true`) for active session feedback. Avoids duplicating the drawing code.
15. **Text auto-dismiss on playback stop** -- Transcript text in CompanionView shows during speaking, auto-dismisses 7s after `isPlaying` goes false. New messages reset the timer. Hovering the orb re-shows dismissed text.
16. **Glass effect .clear variant for text** -- `GlassCapsuleModifier` uses `.glassEffect(.clear)` on macOS 26+ with an explicit `.strokeBorder` overlay. The `.regular` variant causes a double-box deepening effect when the panel becomes key. Falls back to `.ultraThinMaterial` on older macOS.
17. **No GlassEffectContainer** -- Wrapping CompanionView content in `GlassEffectContainer` destroys SwiftUI view identity on state changes, breaking `.onHover` tracking areas and `.task(id:)` reactivity. All content is inline in `body` for stable view identity.
18. **CompanionPanel always visible** -- The panel is created and shown at launch, never hidden. `.canJoinAllSpaces` and `.fullScreenAuxiliary` ensure visibility across desktops and fullscreen apps. `hidesOnDeactivate: false` keeps it visible when the app loses focus.

## Conventions

- Swift 5.9, macOS 14+, SwiftUI + AppKit hybrid
- `@MainActor` for all UI state, `DispatchQueue` for audio/network threads
- `@unchecked Sendable` for classes with manual synchronization (AudioManager, DeepgramAgentClient, ToolRegistry)
- `@Observable` + `@Environment` for SwiftUI state (ConfigStore, DevConsoleState). Use `@Bindable var store = configStore` inside `body` to get bindings.
- Errors returned as strings to LLM (never crash on tool failure)
- Latency values from Voice Agent API are in seconds, converted to ms for display
- All tool handlers have signature `(String) async throws -> String`
- File-level `Logger` instances with subsystem `com.thebrownproject.deepvoice`
- Audio state (isCapturing, isPlaying) pushed from AudioManager to DevConsoleState via callback, not computed properties (bridges `@unchecked Sendable` and `@Observable`)
- In NSPanel/NSHostingView contexts, use `.task(id:)` instead of `.onChange`/`.onAppear` (they don't fire reliably in NSHostingView). Derive visibility from observable state in `body`, not from lifecycle callbacks.
- `.onHover` must be on a view with stable identity. Never pass hover-dependent values as parameters to extracted `@ViewBuilder` methods, as changing parameters destroy view identity and kill hover tracking areas.

## Data Storage

```
~/.deepvoice/
    config.json          # DeepVoiceConfig (providers, model, voice, audio route mode, flags)
    keys.json            # File-based API key fallback (chmod 600, gitignored)
    profile.md           # User profile
    preferences.md       # User preferences
    daily/               # Daily context directory
```
