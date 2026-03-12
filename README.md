# DeepVoice

Voice-first AI desktop companion for macOS. Pure Swift app with a single WebSocket to Deepgram's Voice Agent API for server-side STT + LLM + TTS orchestration. BYO LLM via OpenRouter, client-side tool execution, and a dev console UI.

**Core loop:** Press hotkey -> speak naturally -> Deepgram transcribes -> LLM reasons (via OpenRouter) -> Deepgram speaks back -> tools execute locally on your Mac

**Mental model:** One WebSocket handles everything. No Python backend. No local LLM. The Deepgram Voice Agent API orchestrates speech-to-text, LLM inference, and text-to-speech server-side. Your Mac just sends audio and runs tool calls.


## Architecture

```
macOS App (SwiftUI/AppKit, AVAudioEngine + AudioUnit capture, hotkey, dev console)
    |
    | Single WebSocket (wss://agent.deepgram.com/v1/agent/converse)
    | - Binary frames: PCM16 24kHz mono audio (both directions)
    | - Text frames: JSON control messages (Voice Agent protocol)
    |
    v
Deepgram Voice Agent API (server-side orchestration)
    |-- STT: Deepgram Nova-3
    |-- LLM: BYO via OpenRouter (google/gemini-3.1-flash-lite-preview)
    |-- TTS: Deepgram Aura-2 (aura-2-vesta-en)
    |-- Function calling: client-side (FunctionCallRequest/Response)
```

## Tech Stack

**App:** Swift 5.9 . SwiftUI . AppKit . AVAudioEngine . CoreAudio/AudioUnit . URLSessionWebSocketTask

**Voice Pipeline:** Deepgram Voice Agent API (Nova-3 STT + Aura-2 TTS) . OpenRouter (BYO LLM)

**Tools:** Client-side execution via function calling -- bash, files, AppleScript, screen capture, web search, deep reasoning

**Infrastructure:** macOS Keychain + file fallback (API keys) . KeyboardShortcuts (SPM)

## Features

**Voice Conversation**
- Full-duplex voice loop: speak naturally, hear responses
- Barge-in support (interrupt agent while speaking)
- Conversation history preserved across reconnects within a session
- Voice-optimized output (no markdown artifacts in speech)
- Latency metrics (total, TTS, LLM) logged per turn
- 10s keepalive to maintain WebSocket connection
- Two audio route modes: `Clear Output` and `AirPods Mic`

**Client-Side Tools (8 total)**

| Tool | Purpose | Approval Required |
|------|---------|-------------------|
| `safe_bash` | Shell commands via allowlist + metachar rejection | If confirmDestructive |
| `applescript` | macOS automation via osascript | If confirmDestructive |
| `file_read` | Read files (1MB limit, home dir sandboxed) | No |
| `file_write` | Write files (auto-creates parent dirs) | If confirmDestructive |
| `frontmost_app_context` | Active app info via Accessibility API | No |
| `capture_display` | Screen capture + OpenAI vision analysis | No |
| `reason_deeply` | Delegation to gpt-5-mini for complex reasoning | No |
| `web_search` | Web search via OpenAI Responses API | No |

**Dev Console**
- Real-time log with level filtering (info, warning, error, debug)
- Live transcript display (user + assistant turns)
- Tool approval UI with "always approve" option
- Connection state indicator
- Audio capture/playback status

**Settings**
- API key management (Deepgram, OpenRouter, OpenAI) stored in Keychain
- Voice selection (12 Aura-2 + 3 legacy Aura-1 voices)
- Audio route mode selection for Bluetooth headsets
- LLM model selection (any OpenRouter model)
- Global hotkey configuration
- Safe mode and destructive action confirmation toggles

## Audio Modes

DeepVoice ships with two audio route modes:

- `Clear Output`: uses a built-in or other non-Bluetooth mic for capture and keeps Bluetooth headphones focused on playback quality.
- `AirPods Mic`: uses macOS `VoiceProcessingIO` for headset capture so AirPods-style conversation works more naturally. This mode still uses the Bluetooth headset path, so audio may sound like call audio rather than music-quality playback.

Use `Clear Output` if you care most about assistant voice quality. Use `AirPods Mic` if you care most about natural full-duplex conversation on a Bluetooth headset.

## Project Structure

```
DeepVoice/
    Package.swift                     # Swift 5.9+, macOS 14+
    Sources/DeepVoice/
        # Core Voice Agent
        DeepgramAgentClient.swift     # WebSocket client to Voice Agent API
        VoiceAgentSettings.swift      # Settings payload builder (STT/LLM/TTS config)
        FunctionCallHandler.swift     # Bridges FunctionCallRequest to ToolRegistry

        # App
        DeepVoiceApp.swift            # @main app, AppDelegate, delegate wiring
        DevConsoleState.swift         # Console state, log entries, approvals
        DevConsoleView.swift          # Dev console UI
        SettingsView.swift            # API keys, voice, model settings
        TranscriptOverlay.swift       # Live transcript display

        # Tools
        ToolRegistry.swift            # Tool registration, schemas, dispatch
        ShellTools.swift              # safe_bash + applescript
        FileTools.swift               # file_read + file_write
        DesktopTools.swift            # frontmost_app_context + capture_display
        AITools.swift                 # reason_deeply + web_search

        # Shared
        Types.swift                   # AppState, ToolCall, JSONValue, condenseForVoice
        OpenAIClient.swift            # Shared OpenAI API caller and model constants

        # Audio
        AudioManager.swift            # Dual audio modes: HAL capture for clear output, VoiceProcessingIO for headset mic mode

        # Infrastructure
        Config.swift                  # DeepVoiceConfig (providers, model, voice, audio route mode)
        KeychainHelper.swift          # Keychain + file fallback for API keys
        HotkeyManager.swift           # Option+S toggle, Option+Shift+S settings
        Prompts.swift                 # System prompt + delegation prompt
        DesktopContextToolExecutor.swift  # macOS native context tools
    docs/
        architecture.md               # Architecture comparison and migration notes
        provider-comparison.md         # STT/LLM/TTS provider analysis
        spec.md                        # Original specification
        findings.md                    # Research findings
```

## Build

```bash
swift build
swift run        # macOS only, needs mic + screen permissions
```

Requires macOS 14+ with Xcode command line tools.

## API Keys

Set via Settings UI (Option+Shift+S). Stored in macOS Keychain with file-based fallback (`~/.deepvoice/keys.json`) for unsigned builds:

| Key | Purpose |
|-----|---------|
| Deepgram | Voice Agent API (STT + TTS orchestration) |
| OpenRouter | BYO LLM (gemini-3.1-flash-lite-preview by default) |
| OpenAI | reason_deeply delegation, web_search, capture_display vision |

## Data Storage

```
~/.deepvoice/
    config.json          # DeepVoiceConfig (providers, model, voice, audio route mode, flags)
    keys.json            # File-based API key fallback (chmod 600, gitignored)
    profile.md           # User profile
    preferences.md       # User preferences
    daily/               # Daily context directory
```

Keychain: `com.thebrownproject.deepvoice` service.

## Key Design Decisions

1. **Single WebSocket to Deepgram Voice Agent** -- server handles STT+LLM+TTS orchestration, client just sends/receives audio and handles function calls
2. **BYO LLM via OpenRouter** -- `provider.type = "open_ai"` with custom `endpoint` pointing at OpenRouter's OpenAI-compatible API. Use any model.
3. **Client-side function calling** -- all tools run locally on the Mac, results sent back through the WebSocket
4. **Shell metacharacter blocking** -- safe_bash rejects `;|&\`$(){}\\!<>\n\r` before allowlist check to prevent injection
5. **Tool name aliasing** -- LLMs call "bash" instead of "safe_bash". Fixed with prompt instructions, Deepgram alias registration, and client-side FunctionCallHandler mapping.
6. **No Python backend** -- eliminates the local server, IPC protocol, and process management. One process, one WebSocket.
7. **Dev console over floating widget** -- explicit visibility into agent state, logs, and tool calls during development
8. **Two audio route modes** -- `Clear Output` uses HAL capture on a non-Bluetooth mic to preserve playback quality. `AirPods Mic` uses `VoiceProcessingIO` at 44.1kHz for headset capture, then converts to the 24kHz PCM16 wire format Deepgram expects.
9. **Conversation history across reconnects** -- On WebSocket reconnect, transcript history is injected into the system prompt via `UpdatePrompt` so the agent has context from the current session.
10. **ConfigStore as single source of truth** -- `@Observable` ConfigStore shared via SwiftUI `.environment()`. Settings UI binds directly. Config changes propagate live to ToolRegistry via `withObservationTracking`.

## Background

DeepVoice started as a spike inside the [Samantha](https://github.com/thebrownproject/samantha) project to evaluate replacing the Python backend (OpenAI Agents SDK + local WebSocket IPC) with a pure Swift approach using Deepgram's Voice Agent API. The spike proved the architecture works: same voice quality, simpler stack, 10-50x cheaper than OpenAI Realtime.
