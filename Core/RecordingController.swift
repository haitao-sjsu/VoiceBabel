// RecordingController.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Core dispatcher — central controller managing recording state machine and all transcription backends.
//
// Responsibilities:
//   1. State machine: idle -> recording -> processing -> (waitingToSend ->) idle, error 3s auto-recovery
//   2. API mode routing: route to local/cloud transcription flows
//   3. Translation: Whisper API direct + two-step (transcribe+GPT translate)
//   4. Text cleanup pipeline: post-process via TextCleanupService
//   5. Auto-send logic: off/always/delayed
//   6. Audio validation: min data size + RMS threshold
//   7. Network fallback: Cloud API failure -> local WhisperKit
//
// Dependencies:
//   - AudioRecorder, CloudOpenAIService, LocalWhisperService
//   - TextCleanupService, TextInputter, Config, EngineeringOptions, LocaleManager

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
    private var cloudOpenAIService: CloudOpenAIService
    private let localWhisperService: LocalWhisperService
    private let textInputter: TextInputter
    private var textCleanupService: TextCleanupService
    private let config: Config
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
    var transcriptionPriority: [String] = SettingsDefaults.transcriptionPriority
    let translationPipeline: TranslationPipeline
    var preferredApiMode: StatusBarController.ApiMode = .cloud
    var currentApiMode: StatusBarController.ApiMode = .cloud
    private(set) var isInFallbackMode: Bool = false
    let autoSendManager: AutoSendManager
    var textCleanupMode: TextCleanupMode = .off
    var playSound: Bool = true
    private var lastRecordingDuration: TimeInterval = 0

    // MARK: - Init

    init(
        audioRecorder: AudioRecorder,
        cloudOpenAIService: CloudOpenAIService,
        localWhisperService: LocalWhisperService,
        textInputter: TextInputter,
        textCleanupService: TextCleanupService,
        config: Config
    ) {
        self.audioRecorder = audioRecorder
        self.cloudOpenAIService = cloudOpenAIService
        self.localWhisperService = localWhisperService
        self.textInputter = textInputter
        self.textCleanupService = textCleanupService
        self.config = config
        self.autoSendManager = AutoSendManager(textInputter: textInputter)
        self.translationPipeline = TranslationPipeline(
            cloudOpenAIService: cloudOpenAIService,
            localWhisperService: localWhisperService,
            textInputter: textInputter
        )

        // Wire callbacks after all stored properties are initialized
        self.autoSendManager.onStateChange = { [weak self] state in self?.currentState = state }
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
        cloudOpenAIService: CloudOpenAIService,
        textCleanupService: TextCleanupService
    ) {
        let lm = LocaleManager.shared
        guard currentState == .idle || currentState == .error else {
            Log.w(lm.logLocalized("RecordingController: current state") + " \(currentState) " + lm.logLocalized("does not allow service update"))
            return
        }
        self.cloudOpenAIService = cloudOpenAIService
        self.textCleanupService = textCleanupService
        self.translationPipeline.cloudOpenAIService = cloudOpenAIService
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
        if currentApiMode != .local && (KeychainHelper.load() ?? "").isEmpty {
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
                      let nextMode = transcriptionPriority.first(where: { $0 != "local" }),
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
                maxDuration: config.maxRecordingDuration
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
        let lm = LocaleManager.shared
        let savedSamples = audioRecorder.getAudioSamples()
        let audioDuration = audioRecorder.getCurrentRecordingDuration()
        lastRecordingDuration = audioDuration

        guard let recording = stopAndValidateRecording() else { return }

        currentState = .processing
        let startIndex = transcriptionPriority.firstIndex(of: "cloud") ?? 0
        transcribeWithFallback(recording: recording, samples: savedSamples, audioDuration: audioDuration, priorityIndex: startIndex)
    }

    /// 按优先级队列尝试转录，失败时自动 fallback 到下一个模式
    private func transcribeWithFallback(
        recording: AudioRecorder.RecordingResult,
        samples: [Float],
        audioDuration: TimeInterval,
        priorityIndex: Int
    ) {
        let lm = LocaleManager.shared
        let priority = transcriptionPriority

        guard priorityIndex < priority.count else {
            handleError(String(localized: "All transcription modes failed"))
            return
        }

        // 非首次尝试时检查 fallback 开关
        if priorityIndex > 0 && !EngineeringOptions.enableModeFallback {
            handleError(String(localized: "Transcription failed"))
            return
        }

        let mode = priority[priorityIndex]
        let tryNext: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                self?.transcribeWithFallback(recording: recording, samples: samples, audioDuration: audioDuration, priorityIndex: priorityIndex + 1)
            }
        }

        switch mode {
        case "cloud":
            Log.i(lm.logLocalized("Calling Whisper API (cloud transcription)..."))
            cloudOpenAIService.transcribe(audioData: recording.data, format: recording.format, audioDuration: audioDuration) { [weak self] result in
                switch result {
                case .success:
                    self?.handleResult(result, action: lm.logLocalized("Cloud speech recognition"))
                case .failure(let error):
                    if let whisperError = error as? CloudOpenAIService.WhisperError,
                       case .networkError = whisperError {
                        Log.w(lm.logLocalized("Cloud API failed, trying next priority:") + " \(error.localizedDescription)")
                        self?.enterFallbackMode(mode: "cloud")
                        tryNext()
                    } else {
                        self?.handleResult(result, action: lm.logLocalized("Cloud speech recognition"))
                    }
                }
            }

        case "local":
            guard localWhisperService.isReady() else {
                Log.w(lm.logLocalized("Local WhisperKit not ready, trying next priority"))
                tryNext()
                return
            }
            guard !samples.isEmpty else {
                Log.w(lm.logLocalized("No audio samples for local transcription, trying next priority"))
                tryNext()
                return
            }
            Log.i(lm.logLocalized("Using local WhisperKit transcription..."))
            localTranscribeWithFallback(samples: samples, recording: recording, audioDuration: audioDuration, priorityIndex: priorityIndex)

        default:
            tryNext()
        }
    }

    /// 本地转录，失败时尝试下一个优先级
    private func localTranscribeWithFallback(
        samples: [Float],
        recording: AudioRecorder.RecordingResult,
        audioDuration: TimeInterval,
        priorityIndex: Int
    ) {
        let lm = LocaleManager.shared
        let sampleDuration = Double(samples.count) / EngineeringOptions.sampleRate
        let minutes = sampleDuration / 60.0
        let timeout = min(max(minutes * 10, EngineeringOptions.apiProcessingTimeoutMin), EngineeringOptions.apiProcessingTimeoutMax)
        let action = lm.logLocalized("Local speech recognition")

        Task {
            do {
                let text = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await self.localWhisperService.transcribe(samples: samples)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw CancellationError()
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                await MainActor.run {
                    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedText.isEmpty {
                        Log.i("\(action) " + lm.logLocalized("result is empty"))
                        self.currentState = .idle
                    } else {
                        self.outputText(trimmedText, action: action)
                    }
                }
            } catch {
                await MainActor.run {
                    Log.e("\(action) " + lm.logLocalized("failed:") + " \(error)")
                    if EngineeringOptions.enableModeFallback && priorityIndex + 1 < self.transcriptionPriority.count {
                        Log.w(lm.logLocalized("Local transcription failed, trying next priority"))
                        self.enterFallbackMode(mode: "local")
                        self.transcribeWithFallback(recording: recording, samples: samples, audioDuration: audioDuration, priorityIndex: priorityIndex + 1)
                    } else {
                        self.handleError(String(localized: "\(action) failed: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    /// 进入 fallback 模式，更新 currentApiMode
    private func enterFallbackMode(mode: String) {
        let lm = LocaleManager.shared
        if !isInFallbackMode {
            isInFallbackMode = true
            Log.i(lm.logLocalized("Entered fallback mode, original mode:") + " \(mode)")
        }
        // 更新 currentApiMode 为下一个可用模式
        let nextIndex = (transcriptionPriority.firstIndex(of: mode) ?? -1) + 1
        if nextIndex < transcriptionPriority.count {
            let nextMode = transcriptionPriority[nextIndex]
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

        // Get encoded recording for potential cloud fallback
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

        if let recording = recording {
            let startIndex = transcriptionPriority.firstIndex(of: "local") ?? 0
            localTranscribeWithFallback(samples: samples, recording: recording, audioDuration: audioDuration, priorityIndex: startIndex)
        } else {
            // No encoded data, can only try local (no cloud fallback possible)
            localTranscribeWithTimeout(samples: samples, action: lm.logLocalized("Local speech recognition"))
        }
    }

    private func localTranscribeWithTimeout(samples: [Float], action: String) {
        let lm = LocaleManager.shared
        let audioDuration = Double(samples.count) / EngineeringOptions.sampleRate
        let minutes = audioDuration / 60.0
        let timeout = min(max(minutes * 10, EngineeringOptions.apiProcessingTimeoutMin), EngineeringOptions.apiProcessingTimeoutMax)
        Log.i("\(action): " + lm.logLocalized("audio duration") + " \(String(format: "%.1f", audioDuration))s, " + lm.logLocalized("local processing timeout") + " \(String(format: "%.0f", timeout))s")

        Task {
            do {
                let text = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await self.localWhisperService.transcribe(samples: samples)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw CancellationError()
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                await MainActor.run {
                    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedText.isEmpty {
                        Log.i("\(action) " + lm.logLocalized("result is empty"))
                        self.currentState = .idle
                    } else {
                        self.outputText(trimmedText, action: action)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    Log.e("\(action) " + lm.logLocalized("timed out") + " (\(String(format: "%.0f", timeout))s)")
                    self.handleError(String(localized: "\(action) timed out, try shorter recordings"))
                }
            } catch {
                await MainActor.run {
                    Log.e("\(action) " + lm.logLocalized("failed:") + " \(error)")
                    self.handleError(String(localized: "\(action) failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func handleResult(_ result: Result<String, Error>, action: String) {
        let lm = LocaleManager.shared
        DispatchQueue.main.async { [weak self] in
            switch result {
            case .success(let text):
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedText.isEmpty {
                    Log.i("\(action) " + lm.logLocalized("result is empty"))
                    self?.currentState = .idle
                } else {
                    self?.outputText(trimmedText, action: action)
                }

            case .failure(let error):
                Log.i("\(action) " + lm.logLocalized("failed:") + " \(error)")
                self?.handleError(String(localized: "\(action) failed: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Error Handling

    private func handleError(_ message: String) {
        currentState = .error
        onError?(message)

        DispatchQueue.main.asyncAfter(deadline: .now() + EngineeringOptions.errorRecoveryDelay) { [weak self] in
            if self?.currentState == .error {
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
        if let topMode = transcriptionPriority.first {
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
        let processed = TextPostProcessor.process(text)
        guard textCleanupMode != .off && currentMode != .translate else {
            Log.i("\(action) " + lm.logLocalized("result:") + " \(processed)")
            onTranscriptionResult?(processed)
            textInputter.inputText(processed)
            currentState = .idle
            autoSendManager.handleAutoSend()
            return
        }

        Log.i("\(action) " + lm.logLocalized("result (before cleanup):") + " \(processed)")
        textCleanupService.cleanup(text: processed, mode: textCleanupMode, audioDuration: lastRecordingDuration) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let finalText: String
                switch result {
                case .success(let cleanedText):
                    if cleanedText.isEmpty {
                        Log.w(lm.logLocalized("Text cleanup returned empty result, using original text"))
                        finalText = processed
                    } else {
                        finalText = cleanedText
                    }
                case .failure(let error):
                    Log.w(lm.logLocalized("Text cleanup failed, using original text:") + " \(error.localizedDescription)")
                    finalText = processed
                }
                Log.i("\(action) " + lm.logLocalized("result (final):") + " \(finalText)")
                self.onTranscriptionResult?(finalText)
                self.textInputter.inputText(finalText)
                self.currentState = .idle
                self.autoSendManager.handleAutoSend()
            }
        }
    }

}
