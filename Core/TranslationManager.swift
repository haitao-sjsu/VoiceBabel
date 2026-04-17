// TranslationManager.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Translation engine manager — text-to-text translation with priority-based
// engine fallback. Handles only Step 2 of the two-step flow (translate text).
// Step 1 (transcribe audio) and orchestration live in AppController.
//
// Dependencies:
//   - CloudOpenAIService (GPT text translation via chatTranslate)
//   - LocalAppleTranslationService (Apple Translation, macOS 15.0+, conditional)
//   - SettingsStore, EngineeringOptions, LocaleManager

import Foundation

struct TranslationResult {
    let text: String
    let engine: String           // "apple" / "cloud"
    let fallbackFrom: String?    // non-nil = translation engine fallback occurred
}

class TranslationManager {

    // MARK: - Dependencies

    var cloudOpenAIService: CloudOpenAIService
    #if canImport(Translation)
    var localAppleTranslationService: Any?  // LocalAppleTranslationService, type-erased for availability
    #endif

    // MARK: - Configuration

    var translationEnginePriority: [String] = SettingsDefaults.translationEnginePriority

    // MARK: - Callbacks

    var onResult: ((TranslationResult) -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - State

    private var currentCallStartEngine: String = ""

    // MARK: - Init

    init(cloudOpenAIService: CloudOpenAIService) {
        self.cloudOpenAIService = cloudOpenAIService
    }

    // MARK: - Public

    /// Translate text to the target language using the configured engine priority.
    func translate(text: String, targetLanguage: String) {
        let lm = LocaleManager.shared
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Log.i(lm.logLocalized("Translation input is empty, skipping"))
            onError?(String(localized: "Translation input is empty"))
            return
        }
        Log.i(lm.logLocalized("Starting translation to") + " \(targetLanguage)")
        translateTextWithFallback(trimmed, targetLanguage: targetLanguage, engineIndex: 0)
    }

    // MARK: - Private

    /// Try translation engines in priority order, fallback on failure
    private func translateTextWithFallback(_ text: String, targetLanguage: String, engineIndex: Int) {
        let engines = translationEnginePriority

        guard engineIndex < engines.count else {
            Log.e(LocaleManager.shared.logLocalized("TranslationManager: all translation engines exhausted"))
            onError?(String(localized: "All translation engines failed"))
            return
        }

        if engineIndex > 0 && !EngineeringOptions.enableModeFallback {
            Log.e(LocaleManager.shared.logLocalized("TranslationManager: translation failed and fallback disabled"))
            onError?(String(localized: "Translation failed"))
            return
        }

        if engineIndex == 0 {
            currentCallStartEngine = engines[0]
        }

        let engine = engines[engineIndex]
        Log.i(LocaleManager.shared.logLocalized("TranslationManager: trying engine") + " '\(engine)' (\(engineIndex + 1)/\(engines.count))")
        let tryNext: () -> Void = { [weak self] in
            self?.translateTextWithFallback(text, targetLanguage: targetLanguage, engineIndex: engineIndex + 1)
        }

        switch engine {
        case "apple":
            translateTextViaApple(text, targetLanguage: targetLanguage, engine: engine, onFailure: tryNext)
        case "cloud":
            translateTextViaCloud(text, targetLanguage: targetLanguage, engine: engine, onFailure: tryNext)
        default:
            Log.w("TranslationManager: unknown translation engine '\(engine)', skipping")
            tryNext()
        }
    }

    /// Cloud GPT translation
    private func translateTextViaCloud(_ text: String, targetLanguage: String, engine: String, onFailure: (() -> Void)? = nil) {
        let lm = LocaleManager.shared
        Log.i(lm.logLocalized("Calling GPT translation (cloud)..."))
        cloudOpenAIService.chatTranslate(text: text, targetLanguage: targetLanguage) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    let fallbackFrom = (engine != self.currentCallStartEngine) ? self.currentCallStartEngine : nil
                    self.handleTranslationResult(result, engine: engine, fallbackFrom: fallbackFrom)
                case .failure(let error):
                    if let onFailure = onFailure {
                        Log.w(lm.logLocalized("Cloud GPT translation failed, trying next engine:") + " \(error.localizedDescription)")
                        onFailure()
                    } else {
                        let fallbackFrom = (engine != self.currentCallStartEngine) ? self.currentCallStartEngine : nil
                        self.handleTranslationResult(result, engine: engine, fallbackFrom: fallbackFrom)
                    }
                }
            }
        }
    }

    /// Apple Translation local translation
    private func translateTextViaApple(_ text: String, targetLanguage: String, engine: String, onFailure: (() -> Void)? = nil) {
        let lm = LocaleManager.shared

        #if canImport(Translation)
        guard #available(macOS 15.0, *),
              let service = localAppleTranslationService as? LocalAppleTranslationService else {
            if let onFailure = onFailure {
                Log.i(lm.logLocalized("Apple Translation unavailable, trying next engine"))
                onFailure()
            } else {
                onError?(String(localized: "Apple Translation requires macOS 15.0 or later"))
            }
            return
        }

        Log.i(lm.logLocalized("Calling Apple Translation (local)..."))
        let sourceLang = effectiveWhisperLanguage()
        service.translate(
            text: text,
            sourceLanguage: sourceLang.isEmpty ? nil : sourceLang,
            targetLanguage: targetLanguage
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    let fallbackFrom = (engine != self.currentCallStartEngine) ? self.currentCallStartEngine : nil
                    self.handleTranslationResult(result, engine: engine, fallbackFrom: fallbackFrom)
                case .failure(let error):
                    if let onFailure = onFailure {
                        Log.w(lm.logLocalized("Apple Translation failed, trying next engine:") + " \(error.localizedDescription)")
                        onFailure()
                    } else {
                        let fallbackFrom = (engine != self.currentCallStartEngine) ? self.currentCallStartEngine : nil
                        self.handleTranslationResult(result, engine: engine, fallbackFrom: fallbackFrom)
                    }
                }
            }
        }
        #else
        if let onFailure = onFailure {
            Log.i(lm.logLocalized("Translation framework not available, trying next engine"))
            onFailure()
        } else {
            onError?(String(localized: "Apple Translation is not available on this system"))
        }
        #endif
    }

    /// Handle translation result: build TranslationResult on success, call onError on failure
    private func handleTranslationResult(_ result: Result<String, Error>, engine: String, fallbackFrom: String?) {
        let lm = LocaleManager.shared
        switch result {
        case .success(let translatedText):
            let trimmed = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                Log.i(lm.logLocalized("Translation result is empty"))
                onError?(String(localized: "Translation result is empty"))
            } else {
                Log.i(lm.logLocalized("Translation result:") + " \(trimmed)")
                let output = TranslationResult(text: trimmed, engine: engine, fallbackFrom: fallbackFrom)
                onResult?(output)
            }
        case .failure(let error):
            Log.e(lm.logLocalized("Translation failed:") + " \(error.localizedDescription)")
            onError?(String(localized: "Translation failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Helpers

    /// Resolve the effective whisper language for source language in translation
    private func effectiveWhisperLanguage() -> String {
        let lang = SettingsStore.shared.whisperLanguage
        if lang == "ui" {
            return LocaleManager.whisperCode(for: LocaleManager.shared.currentLocale.language.languageCode?.identifier ?? "en")
        }
        return LocaleManager.whisperCode(for: lang)
    }

}
