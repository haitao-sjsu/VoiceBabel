# Services/

Transcription and translation backends. All services receive API Key via constructor injection (decoupled from storage).

| File | Description |
|------|-------------|
| **CloudOpenAIService.swift** | OpenAI Whisper HTTP client. `transcribe(samples:)` accepts raw `[Float]` PCM samples, encodes internally via AudioEncoder (M4A/WAV), uploads to `/v1/audio/transcriptions` (gpt-4o-transcribe). `chatTranslate()` → Chat Completions API text translation (configurable model via `EngineeringOptions.chatTranslationModel`, supports multi-target language). Manual multipart/form-data, dynamic timeout, custom URLSession per request. Network errors trigger local fallback |
| **LocalAppleTranslationService.swift** | Apple Translation Framework local translation (macOS 15.0+). On-device translation via SwiftUI `.translationTask` bridge (hidden NSWindow host). Auto-detects source language via `NLLanguageRecognizer` and pre-checks language pack availability (fast-fail on missing/unsupported). `#if canImport(Translation)` conditional compilation. Language mapping: WhisperUtil codes → `Locale.Language` (e.g. "zh" → "zh-Hans") |
| **LocalWhisperService.swift** | WhisperKit local transcription. Model `openai_whisper-large-v3-v20240930_626MB` (auto-download on first use). Temperature fallback strategy (0.0 start, 0.2 increment, 5 retries), hallucination detection (compression ratio 2.4), VAD chunking. Post-processing: filter `[MUSIC]`/`[BLANK_AUDIO]` tags, traditional→simplified Chinese |

## Rules — Language Codes & Silent Fallbacks

Two bugs shipped from this pattern: `""` silently became `"en"`; `nil` silently became `"zh-Hans"`. Don't repeat it.

- **No hardcoded language/locale/model fallback.** Banned: `?? "en"`, `?? "zh"`, `Locale.Language(identifier: someVar ?? "zh-Hans")`.
- **"Auto" propagates as `nil` or `""` to the detection boundary.** Audio → omit `language` param. Text translation → run `NLLanguageRecognizer` first, then pass the detected `Locale.Language`.
- **No default parameter values for language, model, or API identifiers.** `func f(lang: String = "en")` is banned. Force the caller to decide.
- **Normalization ≠ fallback.** `"zh" → "zh-Hans"` (UI code → BCP-47) is deterministic mapping, allowed. `"" → "en"` is invention, forbidden.
- **Fail fast on unknowns.** If a required identifier is missing, log and return an error. Don't substitute a guess to keep the code path alive.
- **No dead code.** Unused methods attract copy-paste reuse of their bad patterns.
- **Hardcoded strings → named constants** in `Config/EngineeringOptions.swift`. Inline literals inside `??` are forbidden.

Before committing, grep your diff for `?? "[a-z]`, `Locale.Language(identifier: "`, `= "en"`, `= "zh"` — justify each hit or remove it.
