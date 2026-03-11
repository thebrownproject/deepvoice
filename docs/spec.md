# Pipecat Migration Spike - Specification

## Purpose

Evaluate migrating Samantha's Python backend from the OpenAI Agents SDK to Pipecat, an open-source real-time voice agent framework. The goal is provider flexibility and cost reduction while maintaining the low-latency voice experience.

## Problem Statement

The current backend is locked to OpenAI for everything:

- Voice loop: `gpt-realtime` at $32/$64 per 1M audio tokens
- Reasoning delegation: `gpt-5-mini-2025-08-07`
- Vision: `gpt-4o-mini`
- Web search: `gpt-4o-mini` with OpenAI's hosted web_search tool

This is expensive and inflexible. A 10-minute conversation can cost several dollars in realtime audio tokens alone. There is no way to swap providers without rewriting the backend.

## What Pipecat Gives Us

Pipecat (BSD-2-Clause, free, built by Daily) is a composable pipeline framework for real-time voice agents. It supports 60+ services and two fundamentally different voice architectures:

### Path A: Native Speech-to-Speech (same as current)

```
Swift App -> WebSocket -> Pipecat -> OpenAI Realtime S2S -> Pipecat -> Swift App
```

- Same latency as current setup
- Same cost as current setup
- But: can hot-swap to Gemini Live, Ultravox, or AWS Nova Sonic
- Benefit: provider flexibility without code changes

### Path B: Orchestrated STT + LLM + TTS (the cost saver)

```
Swift App -> WebSocket -> Pipecat -> Deepgram STT -> Claude/GPT via OpenRouter -> Cartesia TTS -> Swift App
```

- Higher latency (extra STT/TTS round-trips, estimated 200-400ms added)
- Much cheaper (Deepgram STT ~$0.004/min, Cartesia TTS ~$0.04/min, LLM text tokens are cheap)
- Can use any LLM: Claude, Gemini, Llama, Mistral, etc.
- Best voices: ElevenLabs (3000+ voices, cloning), Cartesia (90ms TTFA)

### Path C: Hybrid (best of both)

- Default to Path B (cheap orchestrated) for casual conversation
- Escalate to Path A (native realtime) for complex multi-tool tasks
- Switch at runtime based on complexity detection

## What Stays the Same

- **Swift app**: No changes needed. Same WebSocket transport, same PCM16 audio, same JSON control messages. Pipecat's FastAPI WebSocket transport speaks the same protocol.
- **Tools**: bash, file_read, file_write, applescript, memory_save, memory_search, web_search, frontmost_app_context, capture_display all get re-registered as Pipecat function handlers instead of `@function_tool` decorators. Same logic, different registration.
- **Memory**: SQLite + FTS5 + sqlite-vec stays. Pipecat has a mem0 integration but our custom memory is better suited.
- **System prompt**: Same content, passed as LLM instructions.
- **IPC protocol**: Same binary PCM frames + JSON control messages.

## What Changes

| Component | Current (Agents SDK) | Pipecat |
|-----------|---------------------|---------|
| Agent framework | `RealtimeAgent` + `RealtimeRunner` | `Pipeline` + `PipelineTask` |
| Tool registration | `@function_tool` decorator | `llm.register_function(name, handler)` |
| Voice provider | OpenAI only (6 voices) | Any: OpenAI, ElevenLabs, Cartesia, etc. |
| LLM provider | OpenAI only | Any: OpenAI, Anthropic, Google, OpenRouter |
| STT provider | Built into realtime session | Pluggable: Deepgram, Whisper, etc. |
| Audio transport | Custom WebSocket server | Pipecat FastAPI WebSocket transport |
| Interruption | Custom `InterruptionHandler` | Built-in `InterruptionFrame` + VAD |
| State machine | Custom `EventDispatcher` | Pipecat Flows (optional) |
| Session management | Custom `SessionManager` | Pipecat `PipelineTask` lifecycle |
| Config | `~/.samantha/config.json` | Same, but with provider selection fields |

## Pipecat Flows

Pipecat Flows is an optional add-on that provides structured conversation state management. It could replace our manual state dispatching for:

- **Tool approval flows**: Create an approval node that pauses execution until the user approves/rejects
- **Multi-step tasks**: Decompose complex operations into node sequences
- **Context strategies**: APPEND (grow history), RESET (clear), RESET_WITH_SUMMARY (compress)
- **Global functions**: Tools like memory_search available at every conversation state

For Samantha, Flows would be valuable for the tool approval workflow and managing conversation state across long sessions. It's not required for the initial spike but should be evaluated.

## Cost Comparison (estimated per 10-minute conversation)

| Setup | Estimated Cost |
|-------|---------------|
| Current (gpt-realtime) | $3-5 |
| gpt-realtime-mini (quick win) | $1-2 |
| Pipecat Path A (OpenAI Realtime via Pipecat) | $3-5 (same, but swappable) |
| Pipecat Path B (Deepgram + Claude Sonnet + Cartesia) | $0.10-0.30 |
| Pipecat Path B (Deepgram + GPT-4o-mini + Cartesia) | $0.05-0.15 |

Path B is 10-50x cheaper than the current setup.

## Latency Comparison (estimated)

| Setup | Time to First Audio |
|-------|-------------------|
| Current (gpt-realtime native S2S) | ~300-500ms |
| Pipecat Path A (OpenAI Realtime) | ~300-500ms (same) |
| Pipecat Path B (Deepgram + LLM + Cartesia) | ~500-900ms |
| Pipecat Path B (Deepgram + LLM + ElevenLabs) | ~600-1000ms |

The orchestrated path adds 200-400ms from the extra STT/TTS steps. Whether this is acceptable depends on testing.

## Spike Scope

The spike should prove:

1. Pipecat FastAPI WebSocket transport works with the existing Swift app (binary PCM + JSON control)
2. OpenAI Realtime works through Pipecat (Path A, feature parity with current)
3. Orchestrated pipeline works (Path B, Deepgram + Claude + Cartesia)
4. Tool calling works (at minimum: bash, applescript, memory_save)
5. Interruption handling works in both paths
6. Latency is acceptable for Path B

## Success Criteria

- Swift app connects and works without modification
- Voice conversation works end-to-end
- Tool calls execute and return results
- Interruption clears playback immediately
- Path B latency is under 1 second to first audio
- Provider swap (OpenAI -> Anthropic) works by changing config

## Non-Goals for Spike

- Full tool parity (not all 12 tools need to work)
- Memory system migration
- Pipecat Flows integration
- Production hardening
- Pipecat Swift SDK evaluation (keep our existing Swift app)

## References

- Pipecat repo: https://github.com/pipecat-ai/pipecat (cloned at /Users/fraserbrown/repos/pipecat)
- Pipecat Flows: https://github.com/pipecat-ai/pipecat-flows (cloned at /Users/fraserbrown/repos/pipecat-flows)
- Pipecat docs: https://docs.pipecat.ai
- Pipecat Swift SDK docs: https://docs.pipecat.ai/client/ios/introduction
- Key examples: `examples/foundational/19-openai-realtime-beta.py` (realtime + tools), `06-listen-and-respond.py` (orchestrated), `14-function-calling.py` (tool calling), `37-mem0.py` (memory)
