# Provider Comparison

## Current Cost Profile (OpenAI Only)

Based on a test session with ~620K input tokens on gpt-realtime:

| Model | Input Tokens | Rate | Est. Cost |
|-------|-------------|------|-----------|
| gpt-realtime-2025-08-28 | 619,861 | $32/1M in, $64/1M out | ~$20+ |
| gpt-4o-mini-2024-07-18 | 47,602 | $0.15/1M in, $0.60/1M out | ~$0.04 |
| gpt-5-mini-2025-08-07 | 3,116 | $1.25/1M in, $5/1M out | ~$0.02 |
| gpt-4o-mini-transcribe | 3,457 | included in realtime | $0 |

Total: ~$20+ for one evening of testing. The realtime model is 99% of cost.

## Path A: Native Speech-to-Speech Options

### OpenAI Realtime (current)

| Metric | gpt-realtime | gpt-realtime-mini |
|--------|-------------|-------------------|
| Audio input | $32/1M tokens | $10/1M tokens |
| Audio output | $64/1M tokens | $20/1M tokens |
| Text input | $2.50/1M | $0.60/1M |
| Text output | $10/1M | $2.40/1M |
| Cached audio in | $0.40/1M | $0.40/1M |
| Voices | 6 (alloy, ash, ballad, coral, sage, verse) | Same 6 |
| Tool calling | Excellent | Good |
| Latency | ~300-500ms | ~300-500ms |

Quick win: swap to mini for 69% savings with zero code changes.

### Google Gemini Live

| Metric | Value |
|--------|-------|
| Text input | ~$1.25/1M tokens |
| Text output | ~$10/1M tokens |
| Audio pricing | Per-turn billing (all context tokens) |
| Voices | 30 HD voices, 24 languages |
| Tool calling | Supported |
| Latency | Competitive with OpenAI |

Significantly cheaper. Different SDK (Gemini, not OpenAI). Pipecat has native support via `GeminiMultimodalLiveLLMService`.

### Ultravox

| Metric | Value |
|--------|-------|
| Pricing | Self-hostable (open-weight) or hosted |
| Voices | Via external TTS |
| Tool calling | Supported |
| Latency | Depends on hosting |

Interesting for self-hosting. Pipecat supports it natively.

## Path B: Orchestrated Pipeline Options

### STT Providers

| Provider | Model | Latency | Cost/min | Turn Detection | Pipecat Service |
|----------|-------|---------|----------|---------------|-----------------|
| Deepgram | Nova-3 | ~100ms | $0.0043 | Built-in (Flux) | `DeepgramSTTService` |
| OpenAI | Whisper | ~200ms | $0.006 | No | `OpenAISTTService` |
| AssemblyAI | Universal-2 | ~150ms | $0.005 | Yes | `AssemblyAISTTService` |
| Groq | Whisper | ~50ms | $0.006 | No | `GroqSTTService` |
| Speechmatics | Flow | ~100ms | Custom | Yes | `SpeechmaticsSTTService` |

Recommendation: **Deepgram Nova-3** for best latency/cost/features balance.

### LLM Providers (for text reasoning)

| Provider | Model | Speed (TTFT) | Input/1M | Output/1M | Tool Calling | Pipecat Service |
|----------|-------|-------------|----------|-----------|-------------|-----------------|
| OpenRouter | claude-sonnet-4 | ~200ms | $3.00 | $15.00 | Excellent | Via `OpenAILLMService` with base_url |
| OpenRouter | claude-haiku-4.5 | ~100ms | $0.80 | $4.00 | Good | Same |
| OpenRouter | gpt-4o-mini | ~100ms | $0.15 | $0.60 | Excellent | Same |
| OpenRouter | gemini-2.5-flash | ~150ms | $0.15 | $0.60 | Good | Same |
| Anthropic | claude-sonnet-4 | ~200ms | $3.00 | $15.00 | Excellent | `AnthropicLLMService` |
| Groq | llama-4-maverick | ~50ms | $0.20 | $0.60 | Moderate | `GroqLLMService` |

Recommendation: **Claude Sonnet 4 via OpenRouter** for best tool calling quality, or **GPT-4o-mini via OpenRouter** for cheapest option with good tool calling.

### TTS Providers

| Provider | Model | TTFA | Cost/min | Voices | Quality | Pipecat Service |
|----------|-------|------|----------|--------|---------|-----------------|
| Cartesia | Sonic 3 | 90ms | $0.042 | Custom | Very good | `CartesiaTTSService` |
| ElevenLabs | Turbo v2.5 | ~200ms | $0.08 | 3000+ | Best | `ElevenLabsTTSService` |
| Deepgram | Aura 2 | ~100ms | $0.015 | 12 | Good | `DeepgramTTSService` |
| OpenAI | TTS-1 | ~150ms | $0.015 | 6 | Good | `OpenAITTSService` |
| LMNT | - | ~100ms | Custom | Custom | Good | `LMNTTTSService` |

Recommendation: **Cartesia Sonic 3** for lowest latency, or **ElevenLabs** for best voice quality and customization.

## Recommended Configurations

### Budget Build (cheapest possible)

```
Deepgram Nova-3 (STT) -> GPT-4o-mini via OpenRouter (LLM) -> Deepgram Aura (TTS)
```

Estimated cost per 10-min conversation: ~$0.05-0.10
Estimated latency to first audio: ~500-700ms

### Balanced Build (quality + cost)

```
Deepgram Nova-3 (STT) -> Claude Sonnet 4 via OpenRouter (LLM) -> Cartesia Sonic 3 (TTS)
```

Estimated cost per 10-min conversation: ~$0.15-0.30
Estimated latency to first audio: ~400-600ms

### Premium Build (best quality)

```
Deepgram Nova-3 (STT) -> Claude Sonnet 4 via Anthropic (LLM) -> ElevenLabs Turbo (TTS)
```

Estimated cost per 10-min conversation: ~$0.20-0.40
Estimated latency to first audio: ~500-800ms

### Current Build (for reference)

```
OpenAI Realtime (everything in one model)
```

Estimated cost per 10-min conversation: ~$3-5
Estimated latency to first audio: ~300-500ms

## Key Tradeoffs

### Latency vs Cost

The native S2S path (OpenAI Realtime) has the lowest latency because there's no STT-to-text-to-TTS round trip. The audio goes directly through the model. The orchestrated path adds:
- STT processing: 50-200ms
- LLM time-to-first-token: 50-200ms
- TTS time-to-first-audio: 90-200ms
- Network overhead: 20-50ms

Total added latency: 200-650ms depending on providers chosen.

### Voice Quality

- OpenAI Realtime: Good but limited (6 voices, no customization)
- ElevenLabs: Best quality, voice cloning, 3000+ options
- Cartesia: Very good, fastest latency
- Deepgram Aura: Adequate, cheapest

### Tool Calling Quality

Native S2S models handle tool calling within the audio stream, which means they can start speaking before a tool finishes. Orchestrated pipelines work in turns: STT -> LLM (may call tools) -> wait for results -> continue generating -> TTS. This can feel less fluid for multi-tool interactions.

### Flexibility

The orchestrated path lets you swap any component independently. Bad STT accuracy? Switch from Whisper to Deepgram. Want better voices? Swap Cartesia for ElevenLabs. Want cheaper reasoning? Drop from Claude Sonnet to Haiku. This flexibility is the main architectural advantage over the current locked-in setup.
