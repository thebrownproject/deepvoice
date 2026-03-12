# Verification And Next Steps

This document captures the current verified state of DeepVoice and the recommended order of further work.

## Verified State As Of March 12, 2026

DeepVoice is currently verified in GitHub-hosted macOS CI on the `codex/macos-ci-verify` branch.

Verified workflow:

- `.github/workflows/macos-ci.yml`
- runner: `macos-14`
- commands:
  - `swift build`
  - `swift test --parallel`

Successful hosted macOS runs during this pass:

- `22981896135`
- `22982058465`
- `22982113510`

These runs matter because they prove the project now compiles and the current non-UI test suite passes on a real macOS Swift toolchain, even though local `swift` and `xcodebuild` were not available in the working environment used for development.

## What Is Verified

- Swift package compiles on hosted macOS
- test target builds and passes
- current Voice Agent settings payload shape is aligned with the Deepgram docs checked during this pass
- live `UpdateThink` and `UpdateSpeak` paths compile and are covered by logic tests
- warm-session keepalive scheduling compiles and is covered by logic tests

## What Is Not Yet Verified

These still need a real macOS runtime session, not just hosted CI:

- microphone permission flow
- hotkey behavior
- real capture and playback latency
- interrupt behavior while audio is actively playing
- screen capture permissions and screenshot usefulness at the current compression level
- end-to-end Keychain behavior in a normal user session

## Doc-Constrained Runtime Decisions

The following behavior is intentional and based on the docs checked during this pass:

1. Voice and think configuration changes use Deepgram live update messages when possible.
   - `UpdateSpeak` is used for voice / TTS changes.
   - `UpdateThink` is used for LLM / prompt / tool-shape changes.

2. STT changes still force a reconnect.
   - I did not find a documented live listen-model update path equivalent to `UpdateSpeak` / `UpdateThink`.
   - Because of that, changing STT model or STT provider still refreshes the warm session.

3. Interrupt is still primarily local playback suppression.
   - I did not find a documented explicit Voice Agent cancel/flush message for current speech in the docs checked during this pass.

4. Keepalive is scheduled relative to the last outbound activity.
   - This matches the current Deepgram guidance better than a drifting repeating timer.
   - The client should only send `KeepAlive` while idle, not while audio is actively being sent.

## Recommended Next Step

Do the first real macOS validation before taking on the larger runtime refactor.

Reason:

- CI now gives a clean package baseline.
- The biggest remaining uncertainty is real-device behavior, not compile correctness.
- Pulling more session logic behind protocols is still a good idea, but the best version of that refactor depends on what actually proves awkward or fragile on a real Mac.

## Manual macOS Validation Checklist

When a Mac is available, validate in this order:

1. Launch with valid keys and confirm the app reaches a warm connected state without pressing Talk.
2. Press Talk and confirm mic capture starts without a websocket reconnect.
3. Speak a short prompt and capture:
   - hotkey to capture start
   - capture start to first audio send
   - first audio send to first audio receive
   - first audio receive to playback start
4. Interrupt while the assistant is speaking and confirm playback does not resume until the next valid assistant turn.
5. Change voice and LLM settings while connected and confirm the app uses live `UpdateSpeak` / `UpdateThink` behavior rather than reconnecting.
6. Change STT model and confirm the app refreshes the warm session once.
7. Run a high-output `safe_bash` command and confirm it truncates instead of hanging.
8. Run `capture_display` and confirm the summary is still useful at the current JPEG/downscaled settings.

## After First Real Mac Validation

If the runtime behaves as expected on a real Mac, the next highest-value engineering task is:

- extract protocol seams around `VoiceAgentRuntime`, `DeepgramAgentClient`, and `AudioManager`

That should make it possible to unit test more of:

- warm-session transitions
- interrupt behavior
- reconnect behavior
- config update planning
- approval flow

## Docs Checked During This Pass

- Deepgram configure voice agent
- Deepgram voice agent settings and message flow
- Deepgram `UpdateSpeak`
- Deepgram `UpdateThink`
- Deepgram agent/audio keepalive guidance
- OpenAI chat image input structure for `image_url.detail`
- GitHub Actions Swift on hosted macOS runners
