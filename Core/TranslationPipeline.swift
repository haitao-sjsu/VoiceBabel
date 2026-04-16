// TranslationPipeline.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Translation pipeline — two-step translation flow (transcribe then translate).
//
// Responsibilities:
//   1. Step 1: Transcribe audio using current API mode (cloud or local)
//   2. Step 2: Translate transcribed text via priority engine queue (Apple Translation or Cloud GPT)
//   3. Engine fallback: try next engine in priority list on failure
//
// Dependencies:
//   - ServiceCloudOpenAI (cloud transcription + GPT translation)
//   - ServiceLocalWhisper (local transcription)
//   - ServiceAppleTranslation (Apple Translation, macOS 15.0+, conditional)
//   - TextPostProcessor (post-processing translation output)
//   - TextInputter (text output to active window)
//   - SettingsStore, EngineeringOptions, LocaleManager
//
// Architecture role:
//   Extracted from RecordingController. Owned by RecordingController, communicates
//   results back via callbacks (onTranslationResult, onTranscriptionResult, etc.).

import Foundation

class TranslationPipeline {

    // MARK: - Dependencies

    var whisperService: ServiceCloudOpenAI
    let localWhisperService: ServiceLocalWhisper
    let textInputter: TextInputter
    #if canImport(Translation)
    var appleTranslationService: Any?  // ServiceAppleTranslation, type-erased for availability
    #endif

    // MARK: - Configuration

    var translationEnginePriority: [String] = SettingsDefaults.translationEnginePriority

    // MARK: - Callbacks

    var onTranslationResult: ((String) -> Void)?
    var onTranscriptionResult: ((String) -> Void)?
    var onComplete: (() -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - Init

    init(
        whisperService: ServiceCloudOpenAI,
        localWhisperService: ServiceLocalWhisper,
        textInputter: TextInputter
    ) {
        self.whisperService = whisperService
        self.localWhisperService = localWhisperService
        self.textInputter = textInputter
    }

    // MARK: - Public

    /// Start two-step translation: transcribe audio, then translate text
    func translate(
        recording: AudioRecorder.RecordingResult,
        samples: [Float],
        audioDuration: TimeInterval,
        useLocalTranscription: Bool
    ) {
        let lm = LocaleManager.shared
        let targetLang = SettingsStore.shared.translationTargetLanguage

        Log.i(lm.logLocalized("Starting two-step translation: transcribe then translate to") + " \(targetLang)")

        // Step 1: Transcribe
        if useLocalTranscription && localWhisperService.isReady() {
            Task {
                do {
                    let text = try await localWhisperService.transcribe(samples: samples)
                    await MainActor.run {
                        self.translateStep2(transcribedText: text, targetLanguage: targetLang)
                    }
                } catch {
                    await MainActor.run {
                        Log.e(lm.logLocalized("Transcription (step 1) failed:") + " \(error.localizedDescription)")
                        self.onError?(String(localized: "Transcription failed: \(error.localizedDescription)"))
                    }
                }
            }
        } else {
            whisperService.transcribe(audioData: recording.data, format: recording.format, audioDuration: audioDuration) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text):
                        self?.translateStep2(transcribedText: text, targetLanguage: targetLang)
                    case .failure(let error):
                        Log.e(LocaleManager.shared.logLocalized("Transcription (step 1) failed:") + " \(error.localizedDescription)")
                        self?.onError?(String(localized: "Transcription failed: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    // MARK: - Private

    /// Step 2: Translate already-transcribed text
    private func translateStep2(transcribedText: String, targetLanguage: String) {
        let lm = LocaleManager.shared
        let trimmed = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Log.i(lm.logLocalized("Transcription result is empty, skipping translation"))
            onComplete?()
            return
        }

        Log.i(lm.logLocalized("Two-step translation Step 1 complete, transcription result:") + " \(trimmed)")
        // Save transcription result (recoverable even if translation fails)
        onTranscriptionResult?(trimmed)

        translateTextWithFallback(trimmed, targetLanguage: targetLanguage, engineIndex: 0)
    }

    /// Try translation engines in priority order, fallback on failure
    private func translateTextWithFallback(_ text: String, targetLanguage: String, engineIndex: Int) {
        let engines = translationEnginePriority

        guard engineIndex < engines.count else {
            onError?(String(localized: "All translation engines failed"))
            return
        }

        if engineIndex > 0 && !EngineeringOptions.enableModeFallback {
            onError?(String(localized: "Translation failed"))
            return
        }

        let engine = engines[engineIndex]
        let tryNext: () -> Void = { [weak self] in
            self?.translateTextWithFallback(text, targetLanguage: targetLanguage, engineIndex: engineIndex + 1)
        }

        switch engine {
        case "apple":
            translateTextViaApple(text, targetLanguage: targetLanguage, onFailure: tryNext)
        case "cloud":
            translateTextViaCloud(text, targetLanguage: targetLanguage, onFailure: tryNext)
        default:
            tryNext()
        }
    }

    /// Cloud GPT translation
    private func translateTextViaCloud(_ text: String, targetLanguage: String, onFailure: (() -> Void)? = nil) {
        let lm = LocaleManager.shared
        Log.i(lm.logLocalized("Calling GPT translation (cloud)..."))
        whisperService.chatTranslate(text: text, targetLanguage: targetLanguage) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.handleTranslationResult(result, transcribedText: text)
                case .failure(let error):
                    if let onFailure = onFailure {
                        Log.w(lm.logLocalized("Cloud GPT translation failed, trying next engine:") + " \(error.localizedDescription)")
                        onFailure()
                    } else {
                        self?.handleTranslationResult(result, transcribedText: text)
                    }
                }
            }
        }
    }

    /// Apple Translation local translation
    private func translateTextViaApple(_ text: String, targetLanguage: String, onFailure: (() -> Void)? = nil) {
        let lm = LocaleManager.shared

        #if canImport(Translation)
        guard #available(macOS 15.0, *),
              let service = appleTranslationService as? ServiceAppleTranslation else {
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
                    self.handleTranslationResult(result, transcribedText: text)
                case .failure(let error):
                    if let onFailure = onFailure {
                        Log.w(lm.logLocalized("Apple Translation failed, trying next engine:") + " \(error.localizedDescription)")
                        onFailure()
                    } else {
                        self.handleTranslationResult(result, transcribedText: text)
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

    /// Handle translation result: output on success, preserve transcription on failure
    private func handleTranslationResult(_ result: Result<String, Error>, transcribedText: String) {
        let lm = LocaleManager.shared
        switch result {
        case .success(let translatedText):
            let trimmed = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                Log.i(lm.logLocalized("Translation result is empty"))
                onComplete?()
            } else {
                Log.i(lm.logLocalized("Translation result:") + " \(trimmed)")
                let processed = TextPostProcessor.process(trimmed)
                onTranslationResult?(processed)
                onTranscriptionResult?(transcribedText)
                textInputter.inputText(processed)
                onComplete?()
            }
        case .failure(let error):
            Log.e(lm.logLocalized("Translation (step 2) failed:") + " \(error.localizedDescription)")
            Log.i(lm.logLocalized("Transcription preserved in menu bar"))
            onError?(String(localized: "Translation failed: \(error.localizedDescription). Transcription preserved in menu bar."))
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
