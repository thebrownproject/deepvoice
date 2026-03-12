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
    |-- LLM: BYO via OpenRouter (google/gemini-3.1-flash-lite-preview)
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

Set via Settings UI (Option+Shift+S), stored in macOS Keychain (`com.thebrownproject.deepvoice`):

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
| `UpdateSpeak` / `UpdateThink` / `UpdatePrompt` | Runtime config updates |
| `InjectUserMessage` / `InjectAgentMessage` | Inject text messages |

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
5. **Approval flow via async continuations** -- FunctionCallHandler suspends, AppDelegate shows UI, continuation resumes on approve/reject
6. **Separate audio engines** -- Capture and playback use independent AVAudioEngine instances to prevent Bluetooth HFP mode switch (which degrades all system audio when AirPods mic is used). Capture engine forces built-in mic via CoreAudio.
7. **ConfigStore as single source of truth** -- `@Observable` ConfigStore shared via SwiftUI `.environment()`. Settings UI binds directly to it. Config changes propagate live to ToolRegistry via `withObservationTracking`.
8. **Safe mode blocks destructive tools at execute time** -- When enabled, `ToolRegistry.execute()` rejects destructive tools before running the handler. Off by default.

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

## Data Storage

```
~/.deepvoice/
    config.json          # DeepVoiceConfig (providers, model, voice, flags)
    profile.md           # User profile
    preferences.md       # User preferences
    daily/               # Daily context directory
```
