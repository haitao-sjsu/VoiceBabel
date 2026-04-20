// TranslationManager.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Translation engine manager — text-to-text translation via list-iteration
// over the configured engine priority. Stateless across calls: no fallback
// memory, no per-call stored state.
//
// Responsibilities:
//   1. Resolve target and source languages from SettingsStore on each call.
//   2. Iterate engines in `translationEnginePriority` order (pre-filtered by
//      AppDelegate to enabled ∩ available engines).
//   3. Run TextPostProcessor.process on successful output before returning.
//   4. Return a structured TranslationResult with the winning engine and the
//      full ordered attempts list — or throw TranslationError.allEnginesFailed
//      when every engine failed, or .noEngineAvailable when the priority list
//      is empty on entry.
//
// Non-responsibilities (moved or deleted):
//   - No availability / enablement checks. AppDelegate pre-filters the
//     effective list before pushing it into `translationEnginePriority`.
//
// Dependencies:
//   - CloudOpenAIService.chatTranslate (async throws)
//   - LocalTranslator (async throws, macOS 15.0+ via LocalTranslatorFactory)
//   - SettingsStore, SettingsDefaults, LocaleManager, TextPostProcessor
//
// Note on EngineAttempt:
//   The `EngineAttempt` struct is defined in TranscriptionManager.swift and
//   shared by both Managers (same module, no import needed).

import Foundation

// MARK: - Result + Error Types

struct TranslationResult {
    let text: String                    // post-processed by TextPostProcessor
    let engine: String                  // winning engine ("apple" / "cloud")
    let attempts: [EngineAttempt]       // ordered, last entry is the winner
}

enum TranslationError: Error, LocalizedError {
    case emptyInput
    case noEngineAvailable
    case allEnginesFailed(attempts: [EngineAttempt])
    /// Internal invariant violation — thrown from the private `runEngine`
    /// dispatcher when the `apple` engine is dispatched without a
    /// `LocalTranslator`, or an unknown engine id reaches dispatch. If this
    /// ever surfaces it is a bug in TranslationManager itself, not a
    /// user-facing translation failure.
    case internalInconsistency(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return String(localized: "Translation input is empty")
        case .noEngineAvailable:
            return String(localized: "No translation engine available. Check Settings.")
        case .allEnginesFailed(let attempts):
            let details = attempts
                .map { "\($0.engine): \($0.failure ?? "unknown")" }
                .joined(separator: "; ")
            return String(localized: "All translation engines failed (\(details))")
        case .internalInconsistency(let detail):
            return "TranslationManager internal inconsistency: \(detail)"
        }
    }
}

// MARK: - Manager

class TranslationManager {

    // MARK: Dependencies

    var cloudOpenAIService: CloudOpenAIService
    /// On-device translator, created by `LocalTranslatorFactory.make()`.
    /// `nil` on macOS < 15 (no availability gate surfaces at this level).
    var localTranslator: LocalTranslator?

    // MARK: Configuration

    var translationEnginePriority: [String] = SettingsDefaults.translationEnginePriority

    // MARK: Init

    init(cloudOpenAIService: CloudOpenAIService) {
        self.cloudOpenAIService = cloudOpenAIService
    }

    // MARK: Public — Translate

    /// Translate `text` into the target language resolved from SettingsStore.
    ///
    /// The manager does NOT trim whitespace from the input — callers that want
    /// trimming must do it themselves. An empty string throws `.emptyInput`.
    ///
    /// Iterates `translationEnginePriority` (pre-filtered by AppDelegate to
    /// enabled ∩ available engines); each engine either succeeds (returns) or
    /// fails (logged + recorded, moves on). If the list is empty on entry we
    /// throw `.noEngineAvailable` immediately. Only if every engine fails does
    /// this throw `.allEnginesFailed` with the full attempts list.
    func translate(text: String) async throws -> TranslationResult {
        guard !translationEnginePriority.isEmpty else {
            Log.e("TranslationManager: priority is empty (no enabled + available engine)")
            throw TranslationError.noEngineAvailable
        }

        guard !text.isEmpty else {
            Log.i("TranslationManager: empty input, aborting")
            throw TranslationError.emptyInput
        }

        let targetLanguage = resolveTargetLanguage()
        let sourceLanguage = resolveSourceLanguage()  // may be "" (auto-detect)
        Log.i("TranslationManager: starting translate — priority=\(translationEnginePriority), source='\(sourceLanguage.isEmpty ? "auto" : sourceLanguage)', target='\(targetLanguage)'")

        var attempts: [EngineAttempt] = []

        for engine in translationEnginePriority {
            Log.i("TranslationManager: trying engine '\(engine)'")
            do {
                let raw = try await runEngine(
                    engine,
                    text: text,
                    source: sourceLanguage,
                    target: targetLanguage
                )
                attempts.append(EngineAttempt(engine: engine, failure: nil))
                let processed = TextPostProcessor.process(raw)
                Log.i("TranslationManager: \(engine) succeeded (output length=\(processed.count))")
                return TranslationResult(text: processed, engine: engine, attempts: attempts)
            } catch {
                attempts.append(EngineAttempt(engine: engine, failure: error.localizedDescription))
                Log.w("TranslationManager: \(engine) failed: \(error.localizedDescription)")
                continue
            }
        }

        Log.e("TranslationManager: all engines exhausted (\(attempts.count) attempts)")
        throw TranslationError.allEnginesFailed(attempts: attempts)
    }

    // MARK: Private — Engine Dispatch

    /// Route a single engine attempt to the underlying service. Assumes the
    /// engine has already been filtered into the effective priority list by
    /// AppDelegate — the `apple` branch still defends against a missing
    /// `localTranslator` because it is a separate injected dependency that
    /// can legitimately be nil on macOS < 15 even if the id was not filtered.
    private func runEngine(
        _ engine: String,
        text: String,
        source: String,
        target: String
    ) async throws -> String {
        switch engine {
        case "cloud":
            return try await cloudOpenAIService.chatTranslate(
                text: text,
                targetLanguage: target
            )

        case "apple":
            guard let translator = localTranslator else {
                // Defensive — AppDelegate's probe should have filtered "apple"
                // out of the priority list when the translator is unavailable.
                throw TranslationError.internalInconsistency(
                    "apple engine dispatched without a LocalTranslator"
                )
            }
            return try await translator.translate(
                text: text,
                sourceLanguage: source.isEmpty ? nil : source,
                targetLanguage: target
            )

        default:
            throw TranslationError.internalInconsistency("unknown engine '\(engine)'")
        }
    }

    // MARK: Private — Language Resolution

    /// Resolve the target language from SettingsStore, falling back to the
    /// default only when the stored value is empty (treated as misconfiguration).
    private func resolveTargetLanguage() -> String {
        let stored = SettingsStore.shared.translationTargetLanguage
        if stored.isEmpty {
            Log.w("TranslationManager: translationTargetLanguage is empty, falling back to default '\(SettingsDefaults.translationTargetLanguage)'")
            return SettingsDefaults.translationTargetLanguage
        }
        return stored
    }

    /// Resolve the source language code for translation.
    /// - `"ui"`  → current UI language (whisperCode-normalized). If the UI
    ///   language code is unresolvable, returns `""` (auto-detect) rather than
    ///   inventing a locale, per Services/CLAUDE.md.
    /// - `""`    → `""` (auto-detect propagates as-is).
    /// - other → `LocaleManager.whisperCode(for: lang)`.
    private func resolveSourceLanguage() -> String {
        let lang = SettingsStore.shared.whisperLanguage
        if lang == "ui" {
            if let code = LocaleManager.shared.currentLocale.language.languageCode?.identifier {
                return LocaleManager.whisperCode(for: code)
            }
            Log.w("TranslationManager: UI language code unresolvable, source set to auto-detect")
            return ""
        }
        if lang.isEmpty { return "" }
        return LocaleManager.whisperCode(for: lang)
    }
}
