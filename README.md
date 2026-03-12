# DeepVoice

Voice-first AI desktop companion for macOS. Pure Swift app with a single WebSocket to Deepgram's Voice Agent API for server-side STT + LLM + TTS orchestration. BYO LLM via OpenRouter, client-side tool execution, and a dev console UI.

**Core loop:** Press hotkey -> speak naturally -> Deepgram transcribes -> LLM reasons (Claude via OpenRouter) -> Deepgram speaks back -> tools execute locally on your Mac

**Mental model:** One WebSocket handles everything. No Python backend. No local LLM. The Deepgram Voice Agent API orchestrates speech-to-text, LLM inference, and text-to-speech server-side. Your Mac just sends audio and runs tool calls.

---

## Architecture

```
macOS App (SwiftUI/AppKit, AVAudioEngine, hotkey, dev console)
    |
    | Single WebSocket (wss://agent.deepgram.com/v1/agent/converse)
    | - Binary frames: PCM16 24kHz mono audio (both directions)
    | - Text frames: JSON control messages (Voice Agent protocol)
    |
    v
Deepgram Voice Agent API (server-side orchestration)
    |-- STT: Deepgram Flux General English
    |-- LLM: BYO via OpenRouter (anthropic/claude-sonnet-4)
    |-- TTS: Deepgram Aura-2
    |-- Function calling: client-side (FunctionCallRequest/Response)
```

## Tech Stack

**App:** Swift 5.9 . SwiftUI . AppKit . AVAudioEngine . URLSessionWebSocketTask

**Voice Pipeline:** Deepgram Voice Agent API (Flux STT + Aura-2 TTS) . OpenRouter (BYO LLM)

**Tools:** Client-side execution via function calling -- bash, files, AppleScript, screen capture, web search, deep reasoning

**Infrastructure:** macOS Keychain (API keys) . KeyboardShortcuts (SPM)

## Features

**Voice Conversation**
- Full-duplex voice loop: speak naturally, hear responses
- Barge-in support (interrupt agent while speaking)
- Warm WebSocket session so Talk only starts/stops mic capture
- Live `UpdateThink` / `UpdateSpeak` refreshes for compatible settings changes
- Local latency metrics for capture start, first audio send, first audio receive, and playback start
- Automatic reconnection with exponential backoff
- Idle-aware keepalive scheduled from the last outbound activity to avoid timeout drift

**Client-Side Tools (8 total)**

| Tool | Purpose | Approval Required |
|------|---------|-------------------|
| `safe_bash` | Shell commands via allowlist + metachar rejection | If safeMode or confirmDestructive |
| `applescript` | macOS automation via osascript | If safeMode or confirmDestructive |
| `file_read` | Read files (1MB limit, home dir sandboxed) | No |
| `file_write` | Write files (auto-creates parent dirs) | Hidden in safeMode, otherwise if confirmDestructive |
| `frontmost_app_context` | Active app info via Accessibility API | No |
| `capture_display` | Downscaled JPEG screen capture + OpenAI vision analysis | No |
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
- Voice model selection (freeform Deepgram voice model)
- LLM and STT model selection
- Global hotkey configuration
- Safe mode and destructive action confirmation toggles

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
        DeepVoiceApp.swift            # @main app and thin AppDelegate wiring
        VoiceAgentRuntime.swift       # Voice Agent session controller and runtime state
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
        AudioManager.swift            # Separate capture and playback engines

        # Infrastructure
        Config.swift                  # DeepVoiceConfig (providers, model, voice)
        KeychainHelper.swift          # Keychain storage for API keys
        HotkeyManager.swift           # Option+S toggle, Option+Shift+S settings
        Prompts.swift                 # System prompt + delegation prompt
        DesktopContextToolExecutor.swift  # macOS native context tools
    docs/
        current-architecture.md        # Current DeepVoice runtime and session design
        architecture.md                # Historical Pipecat migration notes
        provider-comparison.md         # Historical provider analysis from the migration spike
        spec.md                        # Historical migration spike specification
        findings.md                    # Historical research findings
```

## Build

```bash
swift build
swift run        # macOS only, needs mic + screen permissions
```

Requires macOS 14+ with Xcode command line tools.

## CI

GitHub Actions can compile and test the package on hosted macOS runners, so you do not need your own Mac just to validate pushes or pull requests.

Current workflow:
- `.github/workflows/macos-ci.yml`
- Runs on `macos-14`
- Executes `swift build` and `swift test --parallel`

Current test coverage focuses on non-UI runtime logic:
- config decoding defaults
- voice-agent settings payload generation
- safe-mode tool registration behavior
- `safe_bash` high-output truncation

Current Voice Agent settings behavior:
- Flux models use Deepgram STT `version: v2`
- non-Flux Deepgram STT models use `version: v1`
- Flux omits `smart_format`, while non-Flux Deepgram STT enables it
- the app relies on Deepgram's default context window behavior instead of forcing `context_length`

## API Keys

Set via Settings UI (Option+Shift+S) or stored in macOS Keychain:

| Key | Purpose |
|-----|---------|
| Deepgram | Voice Agent API (STT + TTS orchestration) |
| OpenRouter | BYO LLM (Claude Sonnet 4 by default) |
| OpenAI | reason_deeply delegation, web_search, capture_display vision |

## Data Storage

```
~/.deepvoice/
    config.json          # DeepVoiceConfig (providers, model, voice, flags)
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
5. **Warm session design** -- keep the Deepgram Voice Agent socket warm, then start/stop only local capture for lower first-response latency
6. **No Python backend** -- eliminates the local server, IPC protocol, and process management. One process, one WebSocket.
7. **Dev console over floating widget** -- explicit visibility into agent state, logs, and tool calls during development

## Background

DeepVoice started as a spike inside the [Samantha](https://github.com/thebrownproject/samantha) project to evaluate replacing the Python backend (OpenAI Agents SDK + local WebSocket IPC) with a pure Swift approach using Deepgram's Voice Agent API. The spike proved the architecture works: same voice quality, simpler stack, 10-50x cheaper than OpenAI Realtime.
