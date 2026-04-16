# Services/

Transcription and translation backends. All services receive API Key via constructor injection (decoupled from storage).

| File | Description |
|------|-------------|
| **CloudOpenAIService.swift** | OpenAI Whisper HTTP client. `transcribe()` → `/v1/audio/transcriptions` (gpt-4o-transcribe). `chatTranslate()` → Chat Completions API text translation (configurable model via `EngineeringOptions.chatTranslationModel`, supports multi-target language). Manual multipart/form-data, dynamic timeout, custom URLSession per request. Network errors trigger local fallback |
| **LocalAppleTranslationService.swift** | Apple Translation Framework local translation (macOS 15.0+). On-device translation via SwiftUI `.translationTask` bridge (hidden NSWindow host). Supports language availability check. `#if canImport(Translation)` conditional compilation. Language mapping: WhisperUtil codes → `Locale.Language` (e.g. "zh" → "zh-Hans") |
| **LocalWhisperService.swift** | WhisperKit local transcription. Model `openai_whisper-large-v3-v20240930_626MB` (auto-download on first use). Temperature fallback strategy (0.0 start, 0.2 increment, 5 retries), hallucination detection (compression ratio 2.4), VAD chunking. Post-processing: filter `[MUSIC]`/`[BLANK_AUDIO]` tags, traditional→simplified Chinese |
| **TextCleanupService.swift** | GPT-4o-mini text cleanup. Three modes: neutral (natural polish), formal (professional tone), casual (conversational). Strictly preserves original language. Falls back to raw text on failure |
