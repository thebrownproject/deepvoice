# Research Findings

## Pipecat Core (v0.0.73+)

**Repo**: https://github.com/pipecat-ai/pipecat
**Cloned to**: /Users/fraserbrown/repos/pipecat
**License**: BSD-2-Clause (free, permissive)
**Maintainer**: Daily (WebRTC infrastructure company)

### Architecture

Frame-based pipeline where all data flows as typed Frame objects:
- `AudioRawFrame`, `OutputAudioRawFrame` (binary audio)
- `TranscriptionFrame` (STT output)
- `LLMTextFrame` (LLM output)
- `FunctionCallFromLLM`, `FunctionCallResultFrame` (tool use)
- `InterruptionFrame`, `UserStartedSpeakingFrame`, `UserStoppedSpeakingFrame` (control)

100+ frame types. Each pipeline stage is a `FrameProcessor` that receives, transforms, and emits frames.

### FastAPI WebSocket Transport

**File**: `src/pipecat/transports/websocket/fastapi.py`

Key classes:
- `FastAPIWebsocketTransport` -- main transport
- `FastAPIWebsocketParams` -- config (sample_rate, channels, wav_header, serializer, timeout)
- `FastAPIWebsocketInputTransport` -- receives binary/text frames
- `FastAPIWebsocketOutputTransport` -- sends frames with audio timing emulation

Audio handling:
- Binary WebSocket frames carry raw PCM audio
- Text WebSocket frames carry JSON control messages
- Audio timing simulated with `_send_interval = (chunk_size / sample_rate) / 2`
- Optional fixed-size PCM packetization via `fixed_audio_packet_size`
- Optional WAV header wrapping

Requires a custom `FrameSerializer` to map between Pipecat frames and our IPC protocol. This is the main integration point for keeping the Swift app unchanged.

### OpenAI Realtime Service

**File**: `src/pipecat/services/openai/realtime/llm.py`

Connects directly to OpenAI's Realtime WebSocket API. Handles:
- Bidirectional audio streaming (24kHz PCM16)
- Session configuration (voice, turn detection, transcription)
- Function/tool calling within the audio stream
- Interruption via `ResponseCancelEvent` + `InputAudioBufferClearEvent`

Tool calling flow:
1. Tool schemas sent via `SessionUpdateEvent` with `SessionProperties.tools`
2. Server sends `response.function_call_arguments.done` events
3. Service creates `FunctionCallFromLLM` frames
4. `run_function_calls()` invokes registered handlers
5. Results sent back via `ConversationItemCreateEvent`
6. Model continues with tool output in context

Interruption:
- `InterruptionFrame` triggers audio buffer clear + response cancel
- Turn detection can be semantic VAD (server-side) or disabled (client-driven)
- Audio truncation with millisecond precision

### Orchestrated Pipeline (STT + LLM + TTS)

**Example**: `examples/foundational/06-listen-and-respond.py`

```python
pipeline = Pipeline([
    transport.input(),
    stt,                    # DeepgramSTTService
    user_aggregator,        # LLMUserContextAggregator
    llm,                    # OpenAILLMService / AnthropicLLMService
    tts,                    # CartesiaTTSService
    transport.output(),
    assistant_aggregator,   # LLMAssistantContextAggregator
])
```

Context management is automatic via the aggregators. User speech accumulates, gets sent to LLM, LLM response streams to TTS, TTS audio streams to transport.

### Tool Calling

**Example**: `examples/foundational/14-function-calling.py`

Registration pattern:
```python
tools = ToolsSchema(standard_tools=[
    FunctionSchema(
        name="get_weather",
        description="Get weather for a location",
        properties={"location": {"type": "string"}},
        required=["location"],
    ),
])

async def fetch_weather(params: FunctionCallParams):
    result = {"temp": 72}
    await params.result_callback(result)

llm.register_function("get_weather", fetch_weather)
```

Parallel execution supported. After tool results return, the LLM is re-invoked with results in context. The model decides if it needs more tools or can respond. Same autonomous loop as the Agents SDK.

### VAD (Voice Activity Detection)

Pipecat includes `SileroVADAnalyzer` for client-side turn detection. Used in the orchestrated path where the LLM doesn't have built-in audio turn detection. Emits `UserStartedSpeakingFrame` and `UserStoppedSpeakingFrame`.

### Memory Integration

**Example**: `examples/foundational/37-mem0.py`

Uses Mem0 as a pipeline processor that sits between user_aggregator and LLM. Injects relevant memories as system context before each LLM call. For Samantha, we'd write a custom `FrameProcessor` wrapping our SQLite + sqlite-vec memory store instead of using Mem0.

### Provider Count

| Category | Count | Notable |
|----------|-------|---------|
| STT | 18 | Deepgram, AssemblyAI, Whisper, Speechmatics |
| LLM | 18+ | OpenAI, Anthropic, Gemini, Groq, OpenRouter |
| TTS | 24 | Cartesia, ElevenLabs, Deepgram, OpenAI |
| S2S | 5 | OpenAI Realtime, Gemini Live, Ultravox, Nova Sonic, Grok |
| Transport | 8+ | FastAPI WS, Daily WebRTC, LiveKit, SmallWebRTC |

## Pipecat Flows (v0.0.23)

**Repo**: https://github.com/pipecat-ai/pipecat-flows
**Cloned to**: /Users/fraserbrown/repos/pipecat-flows
**License**: BSD-2-Clause
**Package**: `pipecat-ai-flows` on PyPI

### What It Adds

A structured conversation state machine on top of Pipecat. Conversations are modeled as a graph of nodes, where each node has:
- `task_messages`: Instructions for that conversation state
- `role_messages`: Persona/role definitions
- `functions`: Available tools in that state
- `pre_actions`: Side effects before LLM inference
- `post_actions`: Side effects after response
- `context_strategy`: How to manage conversation history on transition

### Key Concepts

**NodeConfig**: Defines a conversation state
```python
NodeConfig(
    task_messages=[{"role": "system", "content": "Help the user with their calendar."}],
    functions=[calendar_func, memory_func],
    pre_actions=[inject_memory],
    post_actions=[log_turn],
    context_strategy=ContextStrategy.APPEND,
)
```

**FlowManager**: Orchestrates transitions between nodes
```python
flow_manager = FlowManager(
    task=task,
    llm=llm,
    context_aggregator=context_aggregator,
    initial_node=main_node,
    global_functions=[memory_search_func],
)
```

**Context Strategies**:
- `APPEND`: Keep full history (default)
- `RESET`: Clear on node transition
- `RESET_WITH_SUMMARY`: Summarize before clearing (prevents context bloat)

**Dynamic Branching**: Function handlers return `(result, next_node)` tuples. The next node can be computed dynamically based on tool results, user input, or accumulated state.

**Global Functions**: Tools available at every node (e.g., memory_search, cancel).

**@flows_direct_function**: Modern decorator for cleaner function definitions with auto-schema generation from type hints and docstrings.

### Relevance to Samantha

**High value for**:
- Tool approval workflows (transition to approval node, wait for user decision, transition back)
- Long conversation management (RESET_WITH_SUMMARY prevents context window overflow)
- State-dependent tool availability (different tools in different conversation modes)
- Pre/post-action hooks (memory logging, context injection)

**Lower value for**:
- Simple tool calls (the base tool calling is sufficient)
- Real-time streaming (Flows assumes turn-taking)

**Verdict**: Not needed for the spike, but a strong candidate for production. The tool approval flow alone justifies the integration.

## Swift Client SDK

Pipecat provides an official Swift SDK (separate repo, docs at https://docs.pipecat.ai/client/ios/introduction). However, for the spike we should keep our existing Swift app and WebSocket client. The Pipecat Swift SDK would only matter if we wanted to replace the entire frontend.

Our Swift app is already well-built and handles:
- Audio I/O (AVAudioEngine, 24kHz PCM16)
- WebSocket transport (URLSessionWebSocketTask, 20MB max)
- JSON control protocol (protocol_version 1)
- Tool approval UI
- Dev console logging

This all works. No need to replace it.

## Key Risks

1. **Custom serializer complexity**: Mapping our IPC protocol to Pipecat frames requires a custom FrameSerializer. This is the biggest integration risk.

2. **App tool RPC**: Our `app_tool_call`/`app_tool_result` pattern (backend asks Swift to capture screen) doesn't have a direct Pipecat equivalent. Need to implement as a custom tool handler that communicates through the transport.

3. **Latency regression on Path B**: The orchestrated pipeline will be slower. Need to measure and decide if the cost savings justify it.

4. **Tool approval flow**: Currently handled by the Agents SDK's `needs_approval` flag and `approve_tool_call`/`reject_tool_call` IPC. Need to reimplement in Pipecat, possibly with Flows.

5. **Pipecat maturity**: Smaller community than the Agents SDK. Active development but fewer production deployments in public.
