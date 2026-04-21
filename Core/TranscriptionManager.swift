// TranscriptionManager.swift
// VoiceBabel - macOS menu bar speech-to-text tool
//
// Transcription manager — stateless priority-iterating dispatcher that turns
// audio samples into text via one of the configured engines (cloud / local).
//
// Responsibilities:
//   1. Iterate engines in priority order, always starting at priority[0]
//      (no per-call adaptive selection, no cross-call fallback memory).
//   2. Resolve the transcription language from SettingsStore on each call
//      (no stored language state — services are stateless on language).
//   3. Dispatch to the matching backend:
//        - cloud  → CloudOpenAIService.transcribe(samples:audioDuration:language:)
//        - local  → LocalWhisperService.transcribe(samples:language:audioDuration:)
//      Both are `async throws`; timeouts and wire encoding live inside the
//      service — this manager does not wrap them.
//   4. Run TextPostProcessor on the winning raw text before returning.
//   5. Return a structured TranscriptionResult with the full ordered attempt
//      list; throw TranscriptionError.allEnginesFailed when every engine fails,
//      or TranscriptionError.noEngineAvailable when `priority` is empty.
//
// Non-responsibilities (moved or deleted):
//   - No availability / enablement checks. AppDelegate pre-filters the
//     effective list (enabled ∩ objectively-available) before pushing it
//     into `priority`. Reaching `transcribe(...)` with an empty priority is
//     a signal — not a condition to silently work around — that no engine
//     is currently usable.
//   - No fallback-mode flag, no effectiveStartEngine, no preferred-vs-effective
//     split. Always start from priority[0]; if callers want a different order
//     they change the priority array.
//   - No onResult / onError callbacks. Callers `try await transcribe(...)`.
//   - No recursive tryEngine. Engine iteration is a flat `for` loop.
//
// Dependencies:
//   - CloudOpenAIService (cloud transcription, async throws)
//   - LocalWhisperService (local WhisperKit transcription, async throws)
//   - SettingsStore, SettingsDefaults, LocaleManager, TextPostProcessor
//
// Architecture role:
//   Shared by AppController in transcription mode and as Step 1 of translation.
//   Pure function of inputs + current settings: no state survives across calls.

import Foundation

// MARK: - Shared Types

/// One engine attempt within a single `transcribe` call.
/// `failure` is nil when this attempt succeeded; otherwise it carries the
/// localized failure reason returned by the service.
struct EngineAttempt {
    let engine: String
    let failure: String?
}

/// Structured result of a successful `TranscriptionManager.transcribe` call.
/// `text` is already post-processed. `attempts` is ordered; when non-empty,
/// the last entry is the successful attempt (its `failure` is nil).
struct TranscriptionResult {
    let text: String
    let engine: String
    let attempts: [EngineAttempt]
}

/// Errors thrown by `TranscriptionManager.transcribe`.
enum TranscriptionError: Error, LocalizedError {
    case emptyAudio
    case noEngineAvailable
    case allEnginesFailed(attempts: [EngineAttempt])

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return String(localized: "No audio samples to transcribe")
        case .noEngineAvailable:
            return String(localized: "No transcription engine available. Check Settings.")
        case .allEnginesFailed(let attempts):
            let details = attempts
                .map { "\($0.engine): \($0.failure ?? "unknown")" }
                .joined(separator: "; ")
            return String(localized: "All transcription engines failed (\(details))")
        }
    }
}

// MARK: - Manager

class TranscriptionManager {

    // MARK: Dependencies

    var cloudOpenAIService: CloudOpenAIService
    let localWhisperService: LocalWhisperService

    // MARK: Configuration

    /// Engine priority. Always iterated top-down on every call.
    var priority: [String] = SettingsDefaults.transcriptionPriority

    // MARK: Init

    init(cloudOpenAIService: CloudOpenAIService, localWhisperService: LocalWhisperService) {
        self.cloudOpenAIService = cloudOpenAIService
        self.localWhisperService = localWhisperService
    }

    // MARK: Public API

    /// Transcribe PCM samples, iterating engines in priority order.
    ///
    /// Behavior:
    ///   - Empty priority → throw `TranscriptionError.noEngineAvailable`
    ///     (AppDelegate pre-filters; reaching here with an empty list means
    ///     no engine is both enabled and objectively available).
    ///   - Empty samples → throw `TranscriptionError.emptyAudio` immediately
    ///     (no fallback chain — empty audio is a caller-side mistake).
    ///   - For each engine in `priority`: `await` the service call; on success
    ///     post-process the text and return a `TranscriptionResult`; on failure
    ///     record the error and continue to the next engine.
    ///   - If every engine fails, throw `TranscriptionError.allEnginesFailed`
    ///     with the full attempt list.
    func transcribe(samples: [Float], audioDuration: TimeInterval) async throws -> TranscriptionResult {
        guard !priority.isEmpty else {
            Log.e("TranscriptionManager: priority is empty (no enabled + available engine)")
            throw TranscriptionError.noEngineAvailable
        }

        guard !samples.isEmpty else {
            Log.w(LocaleManager.shared.logLocalized("No audio samples to transcribe"))
            throw TranscriptionError.emptyAudio
        }

        let language = resolveTranscriptionLanguage()
        Log.i("TranscriptionManager: starting, priority=\(priority), language=\(language.isEmpty ? "auto" : language), duration=\(String(format: "%.1f", audioDuration))s")

        var attempts: [EngineAttempt] = []

        for engine in priority {
            Log.i("TranscriptionManager: trying \(engine)")
            do {
                let raw = try await tryEngine(
                    engine,
                    samples: samples,
                    audioDuration: audioDuration,
                    language: language
                )
                attempts.append(EngineAttempt(engine: engine, failure: nil))
                let processed = TextPostProcessor.process(raw)
                Log.i("TranscriptionManager: \(engine) succeeded, chars=\(processed.count)")
                return TranscriptionResult(text: processed, engine: engine, attempts: attempts)
            } catch {
                let description = error.localizedDescription
                attempts.append(EngineAttempt(engine: engine, failure: description))
                Log.w("TranscriptionManager: \(engine) failed: \(description)")
                continue
            }
        }

        Log.e("TranscriptionManager: all engines exhausted, attempts=\(attempts.map { "\($0.engine):\($0.failure ?? "ok")" }.joined(separator: ", "))")
        throw TranscriptionError.allEnginesFailed(attempts: attempts)
    }

    // MARK: Private — Engine Dispatch

    /// Dispatch a single engine call. Each branch forwards to its service with
    /// the service-specific argument order; errors propagate to the caller.
    private func tryEngine(
        _ engine: String,
        samples: [Float],
        audioDuration: TimeInterval,
        language: String
    ) async throws -> String {
        switch engine {
        case "cloud":
            return try await cloudOpenAIService.transcribe(
                samples: samples,
                audioDuration: audioDuration,
                language: language
            )
        case "local":
            return try await localWhisperService.transcribe(
                samples: samples,
                language: language,
                audioDuration: audioDuration
            )
        default:
            // Defensive: availability check already filtered unknowns, but if a
            // future priority value slips through, surface it loudly rather
            // than silently skip — this is a misconfiguration, not a runtime
            // fallback condition.
            throw TranscriptionError.allEnginesFailed(attempts: [
                EngineAttempt(engine: engine, failure: "unknown engine")
            ])
        }
    }

    // MARK: Private — Language Resolution

    /// Resolve the language code to pass to services on this call.
    ///
    /// Rules (matches Services/CLAUDE.md — no hardcoded locale fallbacks):
    ///   - `"ui"` → use the current UI locale's language code (normalized via
    ///     `LocaleManager.whisperCode(for:)`). If the UI code is unresolvable,
    ///     return `""` (auto-detect) — never substitute a hardcoded "en".
    ///   - `""`  → auto-detect (service will omit / `detectLanguage`).
    ///   - anything else → normalize via `LocaleManager.whisperCode(for:)`.
    private func resolveTranscriptionLanguage() -> String {
        let lang = SettingsStore.shared.whisperLanguage
        if lang == "ui" {
            if let code = LocaleManager.shared.currentLocale.language.languageCode?.identifier {
                return LocaleManager.whisperCode(for: code)
            }
            Log.w("TranscriptionManager: UI language code unresolvable, falling back to auto-detect")
            return ""
        }
        if lang.isEmpty { return "" }
        return LocaleManager.whisperCode(for: lang)
    }
}
