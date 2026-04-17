// RecordingController.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Core dispatcher — recording state machine and audio lifecycle. Transcription
// orchestration is delegated to TranscriptionPipeline; translation orchestration
// to TranslationPipeline.
//
// Responsibilities:
//   1. State machine: idle -> recording -> processing -> (waitingToSend ->) idle, error 3s auto-recovery
//   2. Recording lifecycle: begin / stop / cancel
//   3. Audio validation: min data size + RMS threshold
//   4. Network fallback state: owns isInFallbackMode / currentApiMode, updated via
//      TranscriptionPipeline's onFallbackEntered callback
//   5. Result output: trim, post-process, input text to active window, trigger auto-send
//
// Dependencies:
//   - AudioRecorder, TextInputter, AutoSendManager
//   - TranscriptionPipeline, TranslationPipeline (owned, created here)
//   - Config, EngineeringOptions, LocaleManager

import Cocoa

class RecordingController {

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
    var onTranscriptionResult: ((String) -> Void)?
    var onTranslationResult: ((String) -> Void)?

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
    let transcriptionPipeline: TranscriptionPipeline
    let translationPipeline: TranslationPipeline
    var preferredApiMode: StatusBarController.ApiMode = .cloud
    var currentApiMode: StatusBarController.ApiMode = .cloud
    private(set) var isInFallbackMode: Bool = false
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
        self.autoSendManager = AutoSendManager(textInputter: textInputter)
        self.transcriptionPipeline = TranscriptionPipeline(
            cloudOpenAIService: cloudOpenAIService,
            localWhisperService: localWhisperService
        )
        self.translationPipeline = TranslationPipeline(
            transcriptionPipeline: self.transcriptionPipeline,
            cloudOpenAIService: cloudOpenAIService,
            textInputter: textInputter
        )


        // Wire callbacks after all stored properties are initialized
        self.autoSendManager.onStateChange = { [weak self] state in self?.currentState = state }
        // Fallback handler is wired once and shared between transcription/translation callers —
        // fallback state (isInFallbackMode / currentApiMode) is controller-owned, so this path
        // is uniform regardless of who invoked the pipeline.
        self.transcriptionPipeline.onFallbackEntered = { [weak self] mode in
            self?.enterFallbackMode(mode: mode)
        }
        self.translationPipeline.onTranslationResult = { [weak self] text in
            self?.onTranslationResult?(text)
        }
        self.translationPipeline.onTranscriptionResult = { [weak self] text in
            self?.onTranscriptionResult?(text)
        }
        self.translationPipeline.onComplete = { [weak self] in
            guard let self = self else { return }
            self.currentState = .idle
            self.autoSendManager.handleAutoSend()
        }
        self.translationPipeline.onError = { [weak self] message in
            self?.handleError(message)
        }

        setupCallbacks()
    }

    #if canImport(Translation)
    @available(macOS 15.0, *)
    func setLocalAppleTranslationService(_ service: LocalAppleTranslationService) {
        self.localAppleTranslationService = service
        self.translationPipeline.localAppleTranslationService = service
    }
    #endif

    func updateServices(
        cloudOpenAIService: CloudOpenAIService
    ) {
        let lm = LocaleManager.shared
        guard currentState == .idle || currentState == .error else {
            Log.w(lm.logLocalized("RecordingController: current state") + " \(currentState) " + lm.logLocalized("does not allow service update"))
            return
        }
        self.transcriptionPipeline.cloudOpenAIService = cloudOpenAIService
        self.translationPipeline.cloudOpenAIService = cloudOpenAIService
        setupCallbacks()
        Log.i(lm.logLocalized("RecordingController: cloud service updated"))
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
        if currentApiMode != .local && (KeychainHelper.load() ?? "").isEmpty {
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

        let needsApiKey = currentApiMode != .local || currentMode == .translate
        if needsApiKey && (KeychainHelper.load() ?? "").isEmpty {
            onError?(String(localized: "Please configure OpenAI API Key in Settings"))
            return
        }

        autoSendManager.cancelDelayedSendForNewRecording()

        let modeText = currentMode == .transcribe ? lm.logLocalized("speech-to-text") : lm.logLocalized("speech translation")
        let apiModeText: String
        switch currentApiMode {
        case .local:    apiModeText = lm.logLocalized("local")
        case .cloud:    apiModeText = lm.logLocalized("cloud")
        }
        Log.i(lm.logLocalized("Starting recording") + " (\(modeText), \(apiModeText) API)...")

        if !audioRecorder.checkMicrophoneAvailability() {
            Log.i(lm.logLocalized("Microphone occupied"))
            handleError(String(localized: "Microphone is in use by another app"))
            return
        }

        if currentApiMode == .local && currentMode == .transcribe {
            if localWhisperService.isReady() {
                startNonStreamingRecording()
            } else if EngineeringOptions.enableModeFallback,
                      let nextMode = transcriptionPipeline.priority.first(where: { $0 != "local" }),
                      nextMode == "cloud" {
                // Start-time fallback: local not ready, try cloud
                Log.w(lm.logLocalized("WhisperKit not ready, falling back to cloud for this recording"))
                startNonStreamingRecording()
            } else {
                startLocalRecording() // will show error message
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

    private func startLocalRecording() {
        if !localWhisperService.isReady() {
            let message = localWhisperService.isModelLoading
                ? String(localized: "WhisperKit model is loading, please wait...")
                : String(localized: "WhisperKit model not loaded yet, please try again later")
            let lm = LocaleManager.shared
            Log.i(lm.logLocalized("WhisperKit model not ready"))
            onError?(message)
            return
        }

        startNonStreamingRecording()
    }

    func stopRecording() {
        guard currentState == .recording else { return }
        let lm = LocaleManager.shared

        Log.i(lm.logLocalized("Stopping recording..."))
        playStopSound()

        if currentApiMode == .local && currentMode == .transcribe {
            stopLocalRecording()
        } else if currentApiMode == .cloud && currentMode == .transcribe {
            stopCloudRecording()
        } else {
            stopTranslationRecording()
        }
    }

    private func stopAndValidateRecording() -> AudioRecorder.RecordingResult? {
        let lm = LocaleManager.shared
        let averageRMS = audioRecorder.getLastRecordingAverageRMS()

        guard let recording = audioRecorder.stopRecording() else {
            Log.i(lm.logLocalized("No audio data recorded"))
            currentState = .idle
            return nil
        }

        Log.i(lm.logLocalized("Recording ended, data size:") + " \(recording.data.count) bytes, format: \(recording.format), avg volume: \(averageRMS)")

        if EngineeringOptions.enableSilenceDetection {
            if recording.data.count < EngineeringOptions.minAudioDataSize {
                Log.i(lm.logLocalized("Audio too short, ignoring"))
                currentState = .idle
                return nil
            }

            if averageRMS < EngineeringOptions.minVoiceThreshold {
                Log.i(lm.logLocalized("Audio volume too low") + " (\(averageRMS) < \(EngineeringOptions.minVoiceThreshold)), " + lm.logLocalized("likely noise only, skipping recognition"))
                currentState = .idle
                return nil
            }
        }

        return recording
    }

    private func stopCloudRecording() {
        let savedSamples = audioRecorder.getAudioSamples()
        let audioDuration = audioRecorder.getCurrentRecordingDuration()
        lastRecordingDuration = audioDuration

        guard let recording = stopAndValidateRecording() else { return }

        currentState = .processing
        startTranscription(recording: recording, samples: savedSamples, audioDuration: audioDuration, startingEngine: "cloud")
    }

    /// 设置 pipeline 的一次性回调并启动转录。回调每次调用前重置，避免与 TranslationPipeline 串线。
    private func startTranscription(
        recording: AudioRecorder.RecordingResult?,
        samples: [Float],
        audioDuration: TimeInterval,
        startingEngine: String
    ) {
        let lm = LocaleManager.shared

        transcriptionPipeline.onResult = { [weak self] text, engine in
            let actionKey = engine == "cloud" ? "Cloud speech recognition" : "Local speech recognition"
            self?.outputText(text, action: lm.logLocalized(actionKey))
        }
        transcriptionPipeline.onError = { [weak self] message in
            self?.handleError(message)
        }

        transcriptionPipeline.transcribe(
            recording: recording,
            samples: samples,
            audioDuration: audioDuration,
            startingEngine: startingEngine
        )
    }

    /// 进入 fallback 模式，更新 currentApiMode
    private func enterFallbackMode(mode: String) {
        let lm = LocaleManager.shared
        if !isInFallbackMode {
            isInFallbackMode = true
            Log.i(lm.logLocalized("Entered fallback mode, original mode:") + " \(mode)")
        }
        // 更新 currentApiMode 为下一个可用模式
        let nextIndex = (transcriptionPipeline.priority.firstIndex(of: mode) ?? -1) + 1
        if nextIndex < transcriptionPipeline.priority.count {
            let nextMode = transcriptionPipeline.priority[nextIndex]
            switch nextMode {
            case "cloud": currentApiMode = .cloud
            case "local": currentApiMode = .local
            default: break
            }
        }
        onError?(String(localized: "Switched to fallback transcription mode"))
    }

    private func stopTranslationRecording() {
        let audioDuration = audioRecorder.getCurrentRecordingDuration()
        let savedSamples = audioRecorder.getAudioSamples()
        lastRecordingDuration = audioDuration
        guard let recording = stopAndValidateRecording() else { return }

        currentState = .processing
        translationPipeline.translate(
            recording: recording,
            samples: savedSamples,
            audioDuration: audioDuration,
            useLocalTranscription: currentApiMode == .local
        )
    }

    private func stopLocalRecording() {
        let lm = LocaleManager.shared
        let samples = audioRecorder.getAudioSamples()
        let averageRMS = audioRecorder.getLastRecordingAverageRMS()
        let audioDuration = audioRecorder.getCurrentRecordingDuration()
        lastRecordingDuration = audioDuration

        // Get encoded recording for potential cloud fallback (may be nil if encoding failed —
        // pipeline will skip cloud engines in that case)
        let recording = audioRecorder.stopRecording()

        Log.i(lm.logLocalized("Local mode recording ended, sample count:") + " \(samples.count), " + lm.logLocalized("avg volume:") + " \(averageRMS)")

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
        startTranscription(recording: recording, samples: samples, audioDuration: audioDuration, startingEngine: "local")
    }

    // MARK: - Error Handling

    private func handleError(_ message: String) {
        Log.e(LocaleManager.shared.logLocalized("RecordingController: error:") + " \(message)")
        currentState = .error
        onError?(message)

        DispatchQueue.main.asyncAfter(deadline: .now() + EngineeringOptions.errorRecoveryDelay) { [weak self] in
            if self?.currentState == .error {
                Log.i(LocaleManager.shared.logLocalized("RecordingController: auto-recovered from error"))
                self?.currentState = .idle
            }
        }
    }

    // MARK: - Network Fallback & Recovery

    func userDidChangeApiMode(_ mode: StatusBarController.ApiMode) {
        let lm = LocaleManager.shared
        preferredApiMode = mode
        currentApiMode = mode
        if isInFallbackMode {
            isInFallbackMode = false
            Log.i(lm.logLocalized("User manually changed API mode, exiting fallback state"))
        }
    }

    func recoverFromFallback() {
        let lm = LocaleManager.shared
        guard isInFallbackMode else { return }
        isInFallbackMode = false
        // Restore to top priority mode
        if let topMode = transcriptionPipeline.priority.first {
            switch topMode {
            case "cloud": currentApiMode = .cloud
            case "local": currentApiMode = .local
            default: currentApiMode = preferredApiMode
            }
        } else {
            currentApiMode = preferredApiMode
        }
        Log.i(lm.logLocalized("Network recovered, switching back to") + " \(currentApiMode.rawValue) " + lm.logLocalized("mode"))
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

    private func outputText(_ text: String, action: String) {
        let lm = LocaleManager.shared
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Log.i("\(action) " + lm.logLocalized("result is empty"))
            currentState = .idle
            return
        }
        let processed = TextPostProcessor.process(trimmed)
        Log.i("\(action) " + lm.logLocalized("result:") + " \(processed)")
        onTranscriptionResult?(processed)
        textInputter.inputText(processed)
        currentState = .idle
        autoSendManager.handleAutoSend()
    }

}
