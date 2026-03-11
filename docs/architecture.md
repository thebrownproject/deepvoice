# Pipecat Migration - Architecture

## Current Architecture (OpenAI Agents SDK)

```
+-----------------------------------------------------------+
|  Swift macOS App                                          |
|  - Audio I/O (AVAudioEngine, 24kHz PCM16 mono)           |
|  - Dev Console UI                                         |
|  - Hotkey (Option+S)                                      |
|  - Desktop context tools (frontmost_app, capture_display) |
+-----------------------------------------------------------+
         |  WebSocket (ws://localhost:9090)
         |  - Binary: PCM16 audio both directions
         |  - Text: JSON control messages (protocol v1)
         v
+-----------------------------------------------------------+
|  Python Backend                                           |
|                                                           |
|  WSServer (websockets library, max_size=20MB)             |
|       |                                                   |
|  RealtimeRuntime                                          |
|       |                                                   |
|  OpenAI Agents SDK                                        |
|  +-----------------------------------------------------+ |
|  | RealtimeAgent                                        | |
|  |   model: gpt-realtime (WebSocket to OpenAI)         | |
|  |   voice: sage                                        | |
|  |   tools: 12 @function_tool definitions               | |
|  |   turn_detection: semantic_vad                       | |
|  +-----------------------------------------------------+ |
|       |                                                   |
|  Tool Layer                                               |
|  - bash, file_read, file_write, applescript               |
|  - web_search, frontmost_app_context, capture_display     |
|  - memory_save, memory_search, reason_deeply              |
|       |                                                   |
|  Memory (SQLite + FTS5 + sqlite-vec)                      |
+-----------------------------------------------------------+
         |
         v
    OpenAI API (single provider for everything)
```

Limitations:
- Single provider (OpenAI) for voice, reasoning, vision, search
- gpt-realtime is the most expensive model on the market
- Cannot swap LLM without rewriting the backend
- Agents SDK tightly couples transport, LLM, and tool execution

## Proposed Architecture (Pipecat)

### Path A: Native Speech-to-Speech (feature parity)

```
+-----------------------------------------------------------+
|  Swift macOS App (UNCHANGED)                              |
|  - Same audio I/O, same UI, same hotkey                   |
|  - Same WebSocket client, same IPC protocol               |
+-----------------------------------------------------------+
         |  WebSocket (ws://localhost:9090)
         |  - Binary: PCM16 audio (same format)
         |  - Text: JSON control messages (same protocol)
         v
+-----------------------------------------------------------+
|  Python Backend (Pipecat)                                 |
|                                                           |
|  FastAPIWebsocketTransport                                |
|  - audio_in_sample_rate: 24000                            |
|  - audio_out_sample_rate: 24000                           |
|  - Binary frames: InputAudioRawFrame / OutputAudioRawFrame|
|  - Text frames: JSON control via custom serializer        |
|       |                                                   |
|  Pipeline                                                 |
|  +-----------------------------------------------------+ |
|  | transport.input()                                    | |
|  |     |                                                | |
|  | OpenAIRealtimeLLMService                             | |
|  |   model: gpt-realtime / gpt-realtime-mini            | |
|  |   session_properties:                                | |
|  |     turn_detection: SemanticTurnDetection()          | |
|  |     input_audio_transcription: enabled               | |
|  |     tools: [bash, applescript, memory_save, ...]     | |
|  |     instructions: SYSTEM_PROMPT                      | |
|  |     output voice: sage                               | |
|  |     |                                                | |
|  | transport.output()                                   | |
|  +-----------------------------------------------------+ |
|       |                                                   |
|  Tool Handlers (registered via llm.register_function)     |
|  - Same logic as current @function_tool implementations   |
|       |                                                   |
|  Memory (SQLite + FTS5 + sqlite-vec, unchanged)           |
+-----------------------------------------------------------+
         |
         v
    OpenAI Realtime API (same as current, but swappable)
```

This path is a 1:1 migration. Same provider, same cost, same latency. The win is that the pipeline is now composable and the provider can be swapped.

### Path B: Orchestrated STT + LLM + TTS (the cost saver)

```
+-----------------------------------------------------------+
|  Swift macOS App (UNCHANGED)                              |
+-----------------------------------------------------------+
         |  WebSocket (same)
         v
+-----------------------------------------------------------+
|  Python Backend (Pipecat)                                 |
|                                                           |
|  FastAPIWebsocketTransport (same config)                  |
|       |                                                   |
|  Pipeline                                                 |
|  +-----------------------------------------------------+ |
|  | transport.input()                                    | |
|  |     |                                                | |
|  | DeepgramSTTService          (speech -> text)         | |
|  |   model: nova-3                                      | |
|  |   language: en                                       | |
|  |     |                                                | |
|  | SileroVADAnalyzer           (turn detection)         | |
|  |     |                                                | |
|  | user_context_aggregator     (collect user messages)  | |
|  |     |                                                | |
|  | [Optional: MemoryProcessor] (inject past context)    | |
|  |     |                                                | |
|  | OpenAILLMService / AnthropicLLMService               | |
|  |   model: claude-sonnet-4 (via OpenRouter)            | |
|  |   or: gpt-4o-mini (direct)                           | |
|  |   tools: [bash, applescript, memory_save, ...]       | |
|  |   system_prompt: SYSTEM_PROMPT                       | |
|  |     |                                                | |
|  | CartesiaTTSService          (text -> speech)         | |
|  |   model: sonic-3                                     | |
|  |   voice: custom_voice_id                             | |
|  |   sample_rate: 24000                                 | |
|  |     |                                                | |
|  | transport.output()                                   | |
|  |     |                                                | |
|  | assistant_context_aggregator                          | |
|  +-----------------------------------------------------+ |
|       |                                                   |
|  Tool Handlers (same as Path A)                           |
|  Memory (same)                                            |
+-----------------------------------------------------------+
         |
         v
    Multiple providers:
    - Deepgram (STT)
    - OpenRouter / Anthropic / OpenAI (LLM)
    - Cartesia / ElevenLabs (TTS)
```

This path decouples the voice pipeline. Each component is best-in-class and independently swappable. Cost drops 10-50x. Latency increases by 200-400ms.

## Component Mapping

### Transport Layer

| Current | Pipecat |
|---------|---------|
| `WSServer` (custom websockets) | `FastAPIWebsocketTransport` |
| `ws.send_json()` | `transport.output()` via serializer |
| `ws.send_audio()` | `OutputAudioRawFrame` through pipeline |
| `ws.audio_handler` | `InputAudioRawFrame` from `transport.input()` |
| Custom JSON protocol handlers | Custom `FrameSerializer` subclass |

The Pipecat transport handles binary/text WebSocket frames natively. We need a custom serializer to map our existing JSON control protocol (start_listening, stop_listening, interrupt, state_change, transcript, etc.) to Pipecat frames.

### Tool Registration

Current (Agents SDK):
```python
@function_tool(needs_approval=_needs_approval_check)
async def applescript(script: str) -> str:
    """Execute AppleScript to control macOS applications."""
    return await _applescript(script)
```

Pipecat equivalent:
```python
tools = ToolsSchema(standard_tools=[
    FunctionSchema(
        name="applescript",
        description="Execute AppleScript to control macOS applications.",
        properties={
            "script": {"type": "string", "description": "The AppleScript to execute"}
        },
        required=["script"],
    ),
])

async def handle_applescript(params: FunctionCallParams):
    result = await _applescript(params.arguments["script"])
    await params.result_callback({"output": result})

llm.register_function("applescript", handle_applescript)
```

Same underlying logic. Different registration pattern.

### Interruption Handling

| Current | Pipecat |
|---------|---------|
| `InterruptionHandler` class | Built-in `InterruptionFrame` |
| `input_audio_buffer.speech_started` detection | `SileroVADAnalyzer` or realtime turn_detection |
| `session.interrupt()` | `ResponseCancelEvent` + `InputAudioBufferClearEvent` |
| `clear_playback` IPC message | `InterruptionFrame` -> transport clears buffer |
| Manual state transitions | Pipeline frame propagation |

### State Management

| Current | Pipecat |
|---------|---------|
| `AppState` enum + `EventDispatcher` | Pipeline frame types (control flow) |
| `state_change` IPC messages | Custom serializer maps frames to JSON |
| `RealtimeRuntime` orchestration | `PipelineTask` lifecycle |
| Turn tracking (turn_id, latency) | Custom `FrameProcessor` observer |

### App Tool RPC (frontmost_app_context, capture_display)

This is Samantha-specific: the backend asks the Swift app to execute macOS-native tools. In Pipecat, this would be a tool handler that sends a JSON request through the transport and waits for a response -- same as current `WSServer.call_app_tool()`.

## Pipecat Flows Integration (Future)

Pipecat Flows adds structured conversation state management:

```python
main_node = NodeConfig(
    task_messages=[{"role": "system", "content": SYSTEM_PROMPT}],
    functions=[bash_func, applescript_func, memory_func, ...],
    pre_actions=[inject_memory_context],
)

approval_node = NodeConfig(
    task_messages=[{"role": "system", "content": "User must approve this action."}],
    functions=[approve_func, reject_func],
)
```

Useful for:
- Tool approval workflow (transition to approval node, wait, transition back)
- Context strategies (RESET_WITH_SUMMARY for long sessions)
- Global functions (memory_search available everywhere)

Not required for the spike but worth evaluating after Path A/B are proven.

## Provider Options

### STT (Path B)

| Provider | Latency | Cost | Notes |
|----------|---------|------|-------|
| Deepgram Nova-3 | ~100ms | $0.0043/min | Best balance, built-in turn detection |
| OpenAI Whisper | ~200ms | $0.006/min | Good accuracy, higher latency |
| AssemblyAI | ~150ms | $0.005/min | Strong accuracy |

### LLM (Path B)

| Provider | Speed | Cost (1M tokens) | Notes |
|----------|-------|-------------------|-------|
| Claude Sonnet 4 (OpenRouter) | Fast | $3/$15 | Strong tool calling |
| GPT-4o-mini (OpenRouter) | Very fast | $0.15/$0.60 | Cheapest, decent |
| Gemini 2.5 Flash | Fast | $0.15/$0.60 | Good value |
| Claude Haiku 4.5 (OpenRouter) | Fastest | $0.80/$4 | Good for simple tasks |

### TTS (Path B)

| Provider | TTFA | Cost | Notes |
|----------|------|------|-------|
| Cartesia Sonic 3 | 90ms | $0.042/min | Fastest, good quality |
| ElevenLabs | ~200ms | $0.08/min | Best quality, 3000+ voices, cloning |
| Deepgram Aura | ~100ms | $0.015/min | Cheapest |
| OpenAI TTS | ~150ms | $0.015/min | Good quality, 6 voices |

### Native S2S (Path A alternatives)

| Provider | Notes |
|----------|-------|
| OpenAI Realtime | Current, best tool calling |
| Gemini Live | Cheaper, 30 voices, 24 languages |
| Ultravox | Open-weight, self-hostable |
| AWS Nova Sonic | AWS ecosystem |

## Migration Strategy

### Phase 1: Path A (feature parity)

1. Build Pipecat backend using OpenAI Realtime service
2. Custom serializer for existing IPC protocol
3. Re-register all 12 tools as Pipecat function handlers
4. Verify Swift app works unchanged
5. Compare latency and behavior with current backend

### Phase 2: Path B (cost reduction)

1. Build orchestrated pipeline (Deepgram + Claude + Cartesia)
2. Same tool handlers, same serializer
3. Test latency and voice quality
4. A/B compare with Path A

### Phase 3: Provider flexibility

1. Add config-driven provider selection
2. Support hot-swapping LLM/TTS at runtime
3. Evaluate Pipecat Flows for state management
4. Consider Pipecat Swift SDK for future app rewrite

## File Structure (Spike)

```
pipecat-spike-test/
    spec.md                  # This spike specification
    architecture.md          # This architecture document
    provider-comparison.md   # Detailed provider analysis
    findings.md              # Research findings and notes
    src/
        server.py            # FastAPI + Pipecat pipeline
        tools.py             # Tool handler definitions
        serializer.py        # IPC protocol serializer
        config.py            # Provider configuration
```
