# Services/

Transcription backends. All services receive API Key via constructor injection (decoupled from storage).

| File | Description |
|------|-------------|
| **ServiceCloudOpenAI.swift** | OpenAI Whisper HTTP client. `transcribe()` → `/v1/audio/transcriptions` (gpt-4o-transcribe). `translate()` → `/v1/audio/translations` (whisper-1). `translateTwoStep()` → transcribe then GPT Chat Completions translate (more accurate, multi-target language). Manual multipart/form-data, dynamic timeout. Network errors trigger local fallback |
| **ServiceRealtimeOpenAI.swift** | OpenAI Realtime WebSocket streaming. Connects to `wss://api.openai.com/v1/realtime?intent=transcription`. Server VAD (threshold 0.5, silence 500ms), PCM16 input. Callbacks: `onTranscriptionDelta` (incremental) and `onTranscriptionComplete` (final). Connection state machine: disconnected→connecting→connected→configured |
| **ServiceLocalWhisper.swift** | WhisperKit local transcription. Model `openai_whisper-large-v3-v20240930_626MB` (auto-download on first use). Temperature fallback strategy (0.0 start, 0.2 increment, 5 retries), hallucination detection (compression ratio 2.4), VAD chunking. Post-processing: filter `[MUSIC]`/`[BLANK_AUDIO]` tags, traditional→simplified Chinese |
| **ServiceTextCleanup.swift** | GPT-4o-mini text cleanup. Three modes: neutral (natural polish), formal (professional tone), casual (conversational). Strictly preserves original language. Falls back to raw text on failure |
