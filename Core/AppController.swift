// AppController.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Core state machine and flow orchestrator. Manages recording lifecycle,
// dispatches to TranscriptionManager and TranslationManager, handles
// two-step translation orchestration (transcribe then translate).
//
// Responsibilities:
//   1. State machine: idle -> recording -> processing -> (waitingToSend ->) idle, error 3s auto-recovery
//   2. Recording lifecycle: begin / stop / cancel
//   3. Audio validation: min sample count + RMS threshold
//   4. Flow orchestration: transcription mode or two-step translation mode
//   5. Result output: trim, post-process, input text to active window, trigger auto-send
//
// Dependencies:
//   - AudioRecorder, TextInputter, AutoSendManager
//   - TranscriptionManager, TranslationManager (owned, created here)
//   - Config, EngineeringOptions, LocaleManager

import Cocoa

class AppController {

    // MARK: - Types

    enum AppState {
        case idle
        case recording
        case processing
        case waitingToSend
        case error
    }

    enum RecordingMode {
        case transcribe
        case translate
    }

    // MARK: - Callbacks

    var onStateChange: ((AppState) -> Void)?
    var onError: ((String) -> Void)?
    var onTranscriptionResult: ((String, String) -> Void)?   // (text, engine)
    var onTranslationResult: ((String, String) -> Void)?      // (text, engine)

    // MARK: - Dependencies

    private let audioRecorder: AudioRecorder
    private let localWhisperService: LocalWhisperService
    private let textInputter: TextInputter
    #if canImport(Translation)
    private var localAppleTranslationService: Any?  // LocalAppleTranslationService, type-erased for availability
    #endif

    // MARK: - State

    private(set) var currentState: AppState = .idle {
        didSet {
            onStateChange?(currentState)
        }
    }

    private var currentMode: RecordingMode = .transcribe
    let transcriptionManager: TranscriptionManager
    let translationManager: TranslationManager
    var currentApiMode: StatusBarController.ApiMode {
        transcriptionManager.effectiveStartEngine == "local" ? .local : .cloud
    }
    var isInFallbackMode: Bool { transcriptionManager.isInFallbackMode }
    let autoSendManager: AutoSendManager
    var playSound: Bool = true
    private var lastRecordingDuration: TimeInterval = 0

    // MARK: - Init

    init(
        audioRecorder: AudioRecorder,
        cloudOpenAIService: CloudOpenAIService,
        localWhisperService: LocalWhisperService,
        textInputter: TextInputter
    ) {
        self.audioRecorder = audioRecorder
        self.localWhisperService = localWhisperService
        self.textInputter = textInputter
        self.transcriptionManager = TranscriptionManager(
            cloudOpenAIService: cloudOpenAIService,
            localWhisperService: localWhisperService
        )
        self.translationManager = TranslationManager(
            cloudOpenAIService: cloudOpenAIService
        )
        self.autoSendManager = AutoSendManager(textInputter: textInputter)

        self.autoSendManager.onStateChange = { [weak self] state in self?.currentState = state }

        setupCallbacks()
    }

    #if canImport(Translation)
    @available(macOS 15.0, *)
    func setLocalAppleTranslationService(_ service: LocalAppleTranslationService) {
        self.localAppleTranslationService = service
        self.translationManager.localAppleTranslationService = service
    }
    #endif

    func updateServices(cloudOpenAIService: CloudOpenAIService) {
        let lm = LocaleManager.shared
        guard currentState == .idle || currentState == .error else {
            Log.w(lm.logLocalized("AppController: current state") + " \(currentState) " + lm.logLocalized("does not allow service update"))
            return
        }
        self.transcriptionManager.cloudOpenAIService = cloudOpenAIService
        self.translationManager.cloudOpenAIService = cloudOpenAIService
        setupCallbacks()
    }

    // MARK: - Setup

    private func setupCallbacks() {
        audioRecorder.onMaxDurationReached = { [weak self] in
            self?.stopRecording()
        }
    }

    // MARK: - Public Methods

    func beginRecording(mode: RecordingMode) {
        guard currentState == .idle || currentState == .error || currentState == .waitingToSend else {
            let lm = LocaleManager.shared
            Log.i(lm.logLocalized("Cannot start recording, current state:") + " \(currentState)")
            return
        }
        if transcriptionManager.effectiveStartEngine != "local" && (KeychainHelper.load() ?? "").isEmpty {
            Log.w(LocaleManager.shared.logLocalized("API key not configured, cannot start recording"))
            onError?(String(localized: "Please configure OpenAI API Key in Settings"))
            return
        }
        if currentState == .error {
            currentState = .idle
        }
        currentMode = mode
        startRecording()
    }

    func toggleRecording(mode: RecordingMode) {
        let lm = LocaleManager.shared
        switch currentState {
        case .idle:
            currentMode = mode
            startRecording()
        case .recording:
            stopRecording()
        case .processing:
            Log.i(lm.logLocalized("Processing in progress, please wait..."))
        case .waitingToSend:
            autoSendManager.cancelDelayedSend()
        case .error:
            currentState = .idle
        }
    }

    func cancelRecording() {
        let lm = LocaleManager.shared
        switch currentState {
        case .recording:
            Log.i(lm.logLocalized("User cancelled recording"))
            _ = audioRecorder.stopRecording()
            playStopSound()
            currentState = .idle

        case .processing:
            Log.i(lm.logLocalized("User cancelled processing"))
            currentState = .idle

        case .waitingToSend:
            autoSendManager.cancelDelayedSend()

        case .idle, .error:
            break
        }
    }

    // MARK: - Recording Control

    private func startRecording() {
        let lm = LocaleManager.shared

        let needsApiKey = transcriptionManager.effectiveStartEngine != "local" || currentMode == .translate
        if needsApiKey && (KeychainHelper.load() ?? "").isEmpty {
            onError?(String(localized: "Please configure OpenAI API Key in Settings"))
            return
        }

        autoSendManager.cancelDelayedSendForNewRecording()

        let modeText = currentMode == .transcribe ? lm.logLocalized("speech-to-text") : lm.logLocalized("speech translation")
        let apiModeText = transcriptionManager.effectiveStartEngine == "local" ? lm.logLocalized("local") : lm.logLocalized("cloud")
        Log.i(lm.logLocalized("Starting recording") + " (\(modeText), \(apiModeText) API)...")

        if !audioRecorder.checkMicrophoneAvailability() {
            Log.i(lm.logLocalized("Microphone occupied"))
            handleError(String(localized: "Microphone is in use by another app"))
            return
        }

        if transcriptionManager.effectiveStartEngine == "local" && currentMode == .transcribe {
            if localWhisperService.isReady() {
                startNonStreamingRecording()
            } else if EngineeringOptions.enableModeFallback,
                      let nextMode = transcriptionManager.priority.first(where: { $0 != "local" }),
                      nextMode == "cloud" {
                Log.w(lm.logLocalized("WhisperKit not ready, falling back to cloud for this recording"))
                startNonStreamingRecording()
            } else {
                // WhisperKit not ready, show appropriate error
                let message = localWhisperService.isModelLoading
                    ? String(localized: "WhisperKit model is loading, please wait...")
                    : String(localized: "WhisperKit model not loaded yet, please try again later")
                Log.i(lm.logLocalized("WhisperKit model not ready"))
                onError?(message)
            }
        } else {
            startNonStreamingRecording()
        }
    }

    private func startNonStreamingRecording() {
        let lm = LocaleManager.shared
        currentState = .recording
        playStartSound()

        do {
            try audioRecorder.startRecording(
                maxDuration: EngineeringOptions.maxRecordingDuration
            )
        } catch {
            Log.e(lm.logLocalized("Recording start failed:") + " \(error)")
            handleError(String(localized: "Recording start failed: \(error.localizedDescription)"))
        }
    }

    func stopRecording() {
        guard currentState == .recording else { return }
        let lm = LocaleManager.shared
        Log.i(lm.logLocalized("Stopping recording..."))
        playStopSound()
        stopAndDispatch()
    }

    private func stopAndDispatch() {
        let lm = LocaleManager.shared
        let audioDuration = audioRecorder.getCurrentRecordingDuration()
        lastRecordingDuration = audioDuration

        guard let samples = audioRecorder.stopRecording() else {
            Log.i(lm.logLocalized("No audio data recorded"))
            currentState = .idle
            return
        }

        let averageRMS = AudioRecorder.averageRMS(of: samples)
        Log.i(lm.logLocalized("Recording ended, sample count:") + " \(samples.count), " + lm.logLocalized("avg volume:") + " \(averageRMS)")

        if EngineeringOptions.enableSilenceDetection {
            if samples.count < Int(EngineeringOptions.sampleRate * EngineeringOptions.minAudioDuration) {
                Log.i(lm.logLocalized("Audio too short, ignoring"))
                currentState = .idle
                return
            }
            if averageRMS < EngineeringOptions.minVoiceThreshold {
                Log.i(lm.logLocalized("Audio volume too low") + " (\(averageRMS) < \(EngineeringOptions.minVoiceThreshold)), " + lm.logLocalized("likely noise only, skipping recognition"))
                currentState = .idle
                return
            }
        }

        currentState = .processing

        switch currentMode {
        case .transcribe:
            startTranscription(samples: samples, audioDuration: audioDuration)
        case .translate:
            startTranslation(samples: samples, audioDuration: audioDuration)
        }
    }

    // MARK: - Transcription

    private func startTranscription(samples: [Float], audioDuration: TimeInterval) {
        let lm = LocaleManager.shared

        transcriptionManager.onResult = { [weak self] result in
            let actionKey = result.engine == "cloud" ? "Cloud speech recognition" : "Local speech recognition"
            self?.outputText(result.text, action: lm.logLocalized(actionKey), engine: result.engine)
        }
        transcriptionManager.onError = { [weak self] message in
            self?.handleError(message)
        }

        transcriptionManager.transcribe(samples: samples, audioDuration: audioDuration)
    }

    // MARK: - Translation (Two-Step)

    private func startTranslation(samples: [Float], audioDuration: TimeInterval) {
        let lm = LocaleManager.shared
        let targetLang = resolveTargetLanguage()
        Log.i(lm.logLocalized("Starting two-step translation: transcribe then translate to") + " \(targetLang)")

        // Step 1: Transcribe
        transcriptionManager.onResult = { [weak self] result in
            guard let self = self else { return }
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Log.i(lm.logLocalized("Transcription result is empty, skipping translation"))
                self.currentState = .idle
                return
            }

            Log.i(lm.logLocalized("Two-step translation Step 1 complete, transcription result:") + " \(trimmed)")
            self.onTranscriptionResult?(trimmed, result.engine)

            // Step 2: Translate
            self.translationManager.onResult = { [weak self] translationResult in
                guard let self = self else { return }
                let processed = TextPostProcessor.process(translationResult.text)
                Log.i(lm.logLocalized("Translation result:") + " \(processed)")
                self.onTranslationResult?(processed, translationResult.engine)
                self.textInputter.inputText(processed)
                self.currentState = .idle
                self.autoSendManager.handleAutoSend()
            }
            self.translationManager.onError = { [weak self] message in
                Log.e(lm.logLocalized("Translation (step 2) failed:") + " \(message)")
                Log.i(lm.logLocalized("Transcription preserved in menu bar"))
                self?.handleError(String(localized: "Translation failed: \(message). Transcription preserved in menu bar."))
            }
            self.translationManager.translate(text: trimmed, targetLanguage: targetLang)
        }
        transcriptionManager.onError = { [weak self] message in
            Log.e(lm.logLocalized("Transcription (step 1) failed:") + " \(message)")
            self?.handleError(String(localized: "Transcription failed: \(message)"))
        }

        transcriptionManager.transcribe(samples: samples, audioDuration: audioDuration)
    }

    private func resolveTargetLanguage() -> String {
        let stored = SettingsStore.shared.translationTargetLanguage
        if stored.isEmpty {
            Log.w(LocaleManager.shared.logLocalized("translationTargetLanguage is empty, falling back to default"))
            return SettingsDefaults.translationTargetLanguage
        }
        return stored
    }

    // MARK: - Error Handling

    private func handleError(_ message: String) {
        Log.e(LocaleManager.shared.logLocalized("AppController: error:") + " \(message)")
        currentState = .error
        onError?(message)

        DispatchQueue.main.asyncAfter(deadline: .now() + EngineeringOptions.errorRecoveryDelay) { [weak self] in
            if self?.currentState == .error {
                Log.i(LocaleManager.shared.logLocalized("AppController: auto-recovered from error"))
                self?.currentState = .idle
            }
        }
    }

    // MARK: - Network Fallback & Recovery

    func userDidChangeApiMode(_ mode: StatusBarController.ApiMode) {
        let engine = mode == .local ? "local" : "cloud"
        transcriptionManager.userDidChangePreferredEngine(engine)
    }

    func recoverFromFallback() {
        transcriptionManager.recoverFromFallback()
    }

    // MARK: - Helpers

    private func playStartSound() {
        if self.playSound {
            NSSound(named: "Tink")?.play()
        }
    }

    private func playStopSound() {
        if self.playSound {
            NSSound(named: "Pop")?.play()
        }
    }

    // MARK: - Unified Text Output

    private func outputText(_ text: String, action: String, engine: String) {
        let lm = LocaleManager.shared
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Log.i("\(action) " + lm.logLocalized("result is empty"))
            currentState = .idle
            return
        }
        let processed = TextPostProcessor.process(trimmed)
        Log.i("\(action) " + lm.logLocalized("result:") + " \(processed)")
        onTranscriptionResult?(processed, engine)
        textInputter.inputText(processed)
        currentState = .idle
        autoSendManager.handleAutoSend()
    }

}
