# Current Architecture

This document describes the current DeepVoice implementation in this repository.

For older Pipecat migration research, see the other files in `docs/`. Those are historical notes, not the current runtime design.

## Overview

DeepVoice is a pure Swift macOS app built around Deepgram's Voice Agent API.

Current high-level flow:

```text
Hotkey / UI
  -> VoiceAgentRuntime
  -> AudioManager capture engine
  -> DeepgramAgentClient websocket
  -> Deepgram Voice Agent API
     - STT: Deepgram Flux (`flux-general-en` by default)
     - LLM: OpenRouter via OpenAI-compatible endpoint
     - TTS: Deepgram Aura-2 (`aura-2-asteria-en` by default)
  -> AudioManager playback engine
  -> Speaker output
```

The app keeps the Deepgram websocket warm and starts or stops only local mic capture during normal use.

## Main Runtime Pieces

### `VoiceAgentRuntime`

`Sources/DeepVoice/VoiceAgentRuntime.swift`

This is the live session controller. It owns:

- app session state
- runtime config and API key reloads
- tool registry rebuilding
- warm websocket lifecycle
- talk / stop / interrupt behavior
- latency logging
- approval handling for guarded tools

`AppDelegate` is intentionally thin now. It starts and shuts down the runtime but does not own the session logic.

### `DeepgramAgentClient`

`Sources/DeepVoice/DeepgramAgentClient.swift`

This wraps the Voice Agent websocket at:

`wss://agent.deepgram.com/v1/agent/converse`

It is responsible for:

- connecting and reconnecting
- sending `Settings`
- streaming user audio to Deepgram
- receiving assistant audio and events
- function-call request/response transport
- idle-aware keepalive scheduled relative to the last outbound activity

### `AudioManager`

`Sources/DeepVoice/AudioManager.swift`

The audio path uses separate engines for capture and playback.

Important behavior:

- playback is prewarmed
- capture does not need to stop and restart when the first TTS audio arrives
- interrupt suppresses playback without tearing down the warm session
- capture audio is chunked at a smaller buffer size than before to reduce uplink delay

### `VoiceAgentSettingsBuilder`

`Sources/DeepVoice/VoiceAgentSettings.swift`

This builds the Voice Agent `Settings` payload from live runtime config.

Current defaults:

- STT model: `flux-general-en`
- STT API version: `v2` for Flux, `v1` for non-Flux Deepgram STT models
- TTS model: `aura-2-asteria-en`
- `flags.history = false`
- OpenRouter title header: `X-OpenRouter-Title`

The runtime intentionally does not force `context_length` right now. It relies on Deepgram's default behavior unless there is a measured reason to override it.

## Runtime Behavior

### Warm Session Model

On launch, the app tries to connect to Deepgram if the required keys are present.

Normal interaction works like this:

1. websocket connects and stays warm
2. settings are applied once per connection
3. pressing Talk starts local mic capture
4. releasing / stopping Talk stops mic capture only
5. the websocket remains available for the next turn

This avoids paying websocket setup and settings application on every turn.

### Interrupt Semantics

Interrupt currently means:

- suppress local playback immediately
- return UI state to listening
- continue using the warm session

There is not currently a documented explicit Voice Agent "cancel current speech" message in the Deepgram docs we checked, so interruption is implemented primarily through local playback suppression.

### Config Reloads

Changes to config or relevant API keys trigger:

- runtime reload
- tool registry rebuild
- live `UpdateThink` / `UpdateSpeak` messages when Deepgram supports the change
- warm-session refresh when needed (for example STT model changes)

This keeps the settings UI and the actual live runtime in sync.

## Tools

The tool system is fully client-side.

Current default tools:

- `safe_bash`
- `applescript`
- `file_read`
- `file_write` when safe mode is off
- `frontmost_app_context`
- `capture_display`
- `reason_deeply`
- `web_search`

Safe mode currently:

- hides `file_write`
- requires approval for `safe_bash`
- requires approval for `applescript`

## Screen Capture Path

`capture_display` now uses:

- downscaled JPEG instead of full PNG
- low-detail OpenAI vision input
- metadata logging fields for width, original size, and byte count

This was changed specifically to reduce latency and payload size.

## Testing And CI

The repo now includes hosted macOS CI:

- workflow: `.github/workflows/macos-ci.yml`
- runner: `macos-14`
- commands: `swift build`, `swift test --parallel`

Current tests focus on logic that does not require live mic/UI interaction:

- config decoding defaults
- tool registration and safe mode behavior
- Voice Agent settings payload generation
- `safe_bash` truncation under high output

## Known Gaps

These are the main areas still worth improving:

1. The runtime controller is separated from `AppDelegate`, but more of the session logic could still be pushed behind protocol-based seams for deeper unit testing.
2. True end-to-end validation still requires a real macOS environment for mic, hotkey, and screen-permission behavior.
3. If Deepgram adds a documented explicit cancel or flush message for current speech, interruption should use it instead of relying mainly on local suppression.
4. Screenshot fidelity is optimized for latency right now; it may be worth making that user-configurable later.
