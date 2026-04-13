// RecordingController.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Core dispatcher — central controller managing recording state machine and all transcription backends.
//
// Responsibilities:
//   1. State machine: idle -> recording -> processing -> (waitingToSend ->) idle, error 3s auto-recovery
//   2. API mode routing: route to local/cloud/realtime transcription flows
//   3. Translation: Whisper API direct + two-step (transcribe+GPT translate)
//   4. Text cleanup pipeline: post-process via ServiceTextCleanup
//   5. Auto-send logic: off/always/smart
//   6. Audio validation: min data size + RMS threshold
//   7. Network fallback: Cloud API failure -> local WhisperKit
//
// Dependencies:
//   - AudioRecorder, ServiceCloudOpenAI, ServiceRealtimeOpenAI, ServiceLocalWhisper
//   - ServiceTextCleanup, TextInputter, Config, EngineeringOptions, LocaleManager

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

    // MARK: - Dependencies

    private let audioRecorder: AudioRecorder
    private var whisperService: ServiceCloudOpenAI
    private var realtimeService: ServiceRealtimeOpenAI
    private let localWhisperService: ServiceLocalWhisper
    private let textInputter: TextInputter
    private var textCleanupService: ServiceTextCleanup
    private let config: Config

    // MARK: - State

    private(set) var currentState: AppState = .idle {
        didSet {
            onStateChange?(currentState)
        }
    }

    private var currentMode: RecordingMode = .transcribe
    var preferredApiMode: StatusBarController.ApiMode = .cloud
    var currentApiMode: StatusBarController.ApiMode = .cloud
    private(set) var isInFallbackMode: Bool = false
    var autoSendMode: StatusBarController.AutoSendMode = .smart
    var smartModeWaitDuration: TimeInterval = UserSettings.smartModeWaitDuration
    var textCleanupMode: TextCleanupMode = .off
    var playSound: Bool = true
    private var lastRecordingDuration: TimeInterval = 0
    private var pendingSendTimer: DispatchWorkItem?

    // MARK: - Init

    init(
        audioRecorder: AudioRecorder,
        whisperService: ServiceCloudOpenAI,
        realtimeService: ServiceRealtimeOpenAI,
        localWhisperService: ServiceLocalWhisper,
        textInputter: TextInputter,
        textCleanupService: ServiceTextCleanup,
        config: Config
    ) {
        self.audioRecorder = audioRecorder
        self.whisperService = whisperService
        self.realtimeService = realtimeService
        self.localWhisperService = localWhisperService
        self.textInputter = textInputter
        self.textCleanupService = textCleanupService
        self.config = config

        setupCallbacks()
    }

    func updateServices(
        whisperService: ServiceCloudOpenAI,
        realtimeService: ServiceRealtimeOpenAI,
        textCleanupService: ServiceTextCleanup
    ) {
        let lm = LocaleManager.shared
        guard currentState == .idle || currentState == .error else {
            Log.w(lm.logLocalized("RecordingController: current state") + " \(currentState) " + lm.logLocalized("does not allow service update"))
            return
        }
        self.whisperService = whisperService
        self.realtimeService = realtimeService
        self.textCleanupService = textCleanupService
        setupCallbacks()
    }

    // MARK: - Setup

    private func setupCallbacks() {
        let lm = LocaleManager.shared

        audioRecorder.onMaxDurationReached = { [weak self] in
            self?.stopRecording()
        }

        realtimeService.onTranscriptionDelta = { [weak self] (delta: String) in
            guard let self = self else { return }
            guard EngineeringOptions.realtimeDeltaMode else { return }
            if self.textCleanupMode == .off {
                self.textInputter.inputTextRaw(delta)
            }
        }
        realtimeService.onTranscriptionComplete = { [weak self] (text: String) in
            guard let self = self else { return }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                Log.i(lm.logLocalized("Realtime: segment transcription complete") + " - \(trimmedText)")
                if self.textCleanupMode != .off {
                    self.outputText(trimmedText, action: lm.logLocalized("Realtime speech recognition"))
                } else {
                    self.onTranscriptionResult?(trimmedText)
                }
            }
        }
        realtimeService.onError = { [weak self] (error: Error) in
            self?.handleError(String(localized: "Realtime transcription error: \(error.localizedDescription)"))
        }
    }

    // MARK: - Public Methods

    /// Resolve the effective whisper language, mapping "ui" to the interface language code
    private func effectiveWhisperLanguage() -> String {
        let lang = SettingsStore.shared.whisperLanguage
        if lang == "ui" {
            return LocaleManager.whisperCode(for: LocaleManager.shared.currentLocale.language.languageCode?.identifier ?? "en")
        }
        return lang
    }

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
            cancelSmartMode()
        case .error:
            currentState = .idle
        }
    }

    func cancelRecording() {
        let lm = LocaleManager.shared
        switch currentState {
        case .recording:
            Log.i(lm.logLocalized("User cancelled recording"))
            if currentApiMode == .realtime {
                _ = audioRecorder.stopRecording()
                audioRecorder.onAudioChunk = nil
                realtimeService.disconnect()
            } else {
                _ = audioRecorder.stopRecording()
            }
            playStopSound()
            currentState = .idle

        case .processing:
            Log.i(lm.logLocalized("User cancelled processing"))
            currentState = .idle

        case .waitingToSend:
            cancelSmartMode()

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

        cancelSmartModeForNewRecording()

        let modeText = currentMode == .transcribe ? lm.logLocalized("speech-to-text") : lm.logLocalized("speech translation")
        let apiModeText: String
        switch currentApiMode {
        case .local:    apiModeText = lm.logLocalized("local")
        case .cloud:    apiModeText = lm.logLocalized("cloud")
        case .realtime: apiModeText = lm.logLocalized("realtime")
        }
        Log.i(lm.logLocalized("Starting recording") + " (\(modeText), \(apiModeText) API)...")

        if !audioRecorder.checkMicrophoneAvailability() {
            Log.i(lm.logLocalized("Microphone occupied"))
            handleError(String(localized: "Microphone is in use by another app"))
            return
        }

        if currentApiMode == .local && currentMode == .transcribe {
            startLocalRecording()
        } else if currentApiMode == .realtime && currentMode == .transcribe {
            startRealtimeRecording()
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
                maxDuration: config.maxRecordingDuration,
                streamingMode: false
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

    private func startRealtimeRecording() {
        let lm = LocaleManager.shared
        Log.i(lm.logLocalized("Realtime: starting realtime recording flow"))
        realtimeService.disconnect()
        audioRecorder.onAudioChunk = { [weak self] data in
            self?.realtimeService.sendAudioChunk(data)
        }

        realtimeService.resetTranscription()
        realtimeService.onConnectionStateChange = { [weak self] (state: RealtimeConnectionState) in
            guard let self = self else { return }
            Log.i(lm.logLocalized("Realtime: connection state changed to") + " \(state)")

            switch state {
            case .configured:
                DispatchQueue.main.async {
                    Log.i(lm.logLocalized("Realtime: session configured, starting recording"))
                    self.currentState = .recording
                    self.playStartSound()

                    do {
                        try self.audioRecorder.startRecording(
                            maxDuration: self.config.maxRecordingDuration,
                            streamingMode: true,
                            sampleRate: EngineeringOptions.realtimeSampleRate
                        )
                        Log.i(lm.logLocalized("Realtime: recording started (24kHz)"))
                    } catch {
                        Log.e(lm.logLocalized("Realtime: recording start failed:") + " \(error)")
                        self.handleError(String(localized: "Recording start failed: \(error.localizedDescription)"))
                        self.realtimeService.disconnect()
                    }
                }

            case .disconnected:
                DispatchQueue.main.async {
                    Log.w(lm.logLocalized("Realtime: connection disconnected, current state:") + " \(self.currentState)")
                    if self.currentState == .recording {
                        self.handleError(String(localized: "WebSocket connection disconnected"))
                    }
                }

            default:
                Log.d(lm.logLocalized("Realtime: connection state:") + " \(state)")
                break
            }
        }

        Log.i(lm.logLocalized("Realtime: calling connect()..."))
        realtimeService.connect()
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
        } else if currentApiMode == .realtime && currentMode == .transcribe {
            stopRealtimeRecording()
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
        Log.i(lm.logLocalized("Calling Whisper API (cloud transcription)..."))
        whisperService.transcribe(audioData: recording.data, format: recording.format, audioDuration: audioDuration) { [weak self] result in
            switch result {
            case .success:
                self?.handleResult(result, action: lm.logLocalized("Cloud speech recognition"))
            case .failure(let error):
                if self?.shouldFallbackToLocal(error: error) == true {
                    Log.w(lm.logLocalized("Cloud API failed, falling back to local WhisperKit:") + " \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self?.fallbackToLocalTranscription(samples: savedSamples)
                    }
                } else {
                    self?.handleResult(result, action: lm.logLocalized("Cloud speech recognition"))
                }
            }
        }
    }

    private func shouldFallbackToLocal(error: Error) -> Bool {
        guard EngineeringOptions.enableCloudFallback else { return false }
        guard localWhisperService.isReady() else { return false }

        if let whisperError = error as? ServiceCloudOpenAI.WhisperError {
            switch whisperError {
            case .networkError:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func fallbackToLocalTranscription(samples: [Float]) {
        let lm = LocaleManager.shared
        guard !samples.isEmpty else {
            Log.w(lm.logLocalized("Fallback failed: no saved audio samples"))
            handleError(String(localized: "Cloud API failed and cannot fall back to local transcription"))
            return
        }

        Log.i(lm.logLocalized("Falling back to local WhisperKit, sample count:") + " \(samples.count)")

        if !isInFallbackMode {
            isInFallbackMode = true
            currentApiMode = .local
            Log.i(lm.logLocalized("Entered network fallback mode, subsequent transcriptions will use local WhisperKit"))
        }

        onError?(String(localized: "Cloud API timed out, automatically switched to local recognition"))
        localTranscribeWithTimeout(samples: samples, action: lm.logLocalized("Local fallback speech recognition"))
    }

    private func stopTranslationRecording() {
        let audioDuration = audioRecorder.getCurrentRecordingDuration()
        lastRecordingDuration = audioDuration
        guard let recording = stopAndValidateRecording() else { return }

        currentState = .processing
        translateAudio(recording, audioDuration: audioDuration)
    }

    private func stopLocalRecording() {
        let lm = LocaleManager.shared
        let samples = audioRecorder.getAudioSamples()
        let averageRMS = audioRecorder.getLastRecordingAverageRMS()
        lastRecordingDuration = audioRecorder.getCurrentRecordingDuration()

        _ = audioRecorder.stopRecording()

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
        localTranscribeWithTimeout(samples: samples, action: lm.logLocalized("Local speech recognition"))
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

    private func stopRealtimeRecording() {
        _ = audioRecorder.stopRecording()
        audioRecorder.onAudioChunk = nil
        realtimeService.disconnect()
        currentState = .idle
        handleAutoSend()
    }

    // MARK: - Audio Processing

    private func translateAudio(_ recording: AudioRecorder.RecordingResult, audioDuration: TimeInterval) {
        let lm = LocaleManager.shared
        if config.translationMethod == "two-step" {
            Log.i(lm.logLocalized("Calling two-step translation (transcribe + GPT translate)..."))
            whisperService.translateTwoStep(audioData: recording.data, format: recording.format, audioDuration: audioDuration) { [weak self] result in
                self?.handleResult(result, action: lm.logLocalized("Speech translation (two-step)"))
            }
        } else {
            Log.i(lm.logLocalized("Calling Whisper API (direct translation)..."))
            whisperService.translate(audioData: recording.data, format: recording.format, audioDuration: audioDuration) { [weak self] result in
                self?.handleResult(result, action: lm.logLocalized("Speech translation"))
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
        currentApiMode = preferredApiMode
        Log.i(lm.logLocalized("Network recovered, switching back to") + " \(preferredApiMode.rawValue) " + lm.logLocalized("mode"))
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
        guard textCleanupMode != .off && currentMode != .translate else {
            Log.i("\(action) " + lm.logLocalized("result:") + " \(text)")
            onTranscriptionResult?(text)
            textInputter.inputText(text)
            currentState = .idle
            handleAutoSend()
            return
        }

        Log.i("\(action) " + lm.logLocalized("result (before cleanup):") + " \(text)")
        textCleanupService.cleanup(text: text, mode: textCleanupMode, audioDuration: lastRecordingDuration) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let finalText: String
                switch result {
                case .success(let cleanedText):
                    if cleanedText.isEmpty {
                        Log.w(lm.logLocalized("Text cleanup returned empty result, using original text"))
                        finalText = text
                    } else {
                        finalText = cleanedText
                    }
                case .failure(let error):
                    Log.w(lm.logLocalized("Text cleanup failed, using original text:") + " \(error.localizedDescription)")
                    finalText = text
                }
                Log.i("\(action) " + lm.logLocalized("result (final):") + " \(finalText)")
                self.onTranscriptionResult?(finalText)
                self.textInputter.inputText(finalText)
                self.currentState = .idle
                self.handleAutoSend()
            }
        }
    }

    // MARK: - Auto Send

    private func handleAutoSend() {
        let lm = LocaleManager.shared
        switch autoSendMode {
        case .off:
            break

        case .always:
            DispatchQueue.main.asyncAfter(deadline: .now() + EngineeringOptions.autoSendDelay) { [weak self] in
                self?.textInputter.pressReturnKey()
                Log.i(lm.logLocalized("Auto send: pressed Enter"))
            }

        case .smart:
            startSmartModeCountdown()
        }
    }

    private func startSmartModeCountdown() {
        let lm = LocaleManager.shared
        currentState = .waitingToSend
        Log.i(lm.logLocalized("Smart mode: starting") + " \(smartModeWaitDuration)s " + lm.logLocalized("countdown..."))

        let timerWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.currentState == .waitingToSend {
                self.textInputter.pressReturnKey()
                Log.i(lm.logLocalized("Smart mode: countdown ended, auto sent"))
                self.cleanupSmartMode()
                self.currentState = .idle
            }
        }
        pendingSendTimer = timerWork
        DispatchQueue.main.asyncAfter(deadline: .now() + smartModeWaitDuration, execute: timerWork)
    }

    private func cancelSmartMode() {
        let lm = LocaleManager.shared
        cleanupSmartMode()
        currentState = .idle
        Log.i(lm.logLocalized("Smart mode: user pressed hotkey to cancel send, text preserved"))
    }

    private func cancelSmartModeForNewRecording() {
        let lm = LocaleManager.shared
        if currentState == .waitingToSend {
            Log.i(lm.logLocalized("Smart mode: user started new recording, cancelling send countdown"))
            cleanupSmartMode()
        }
    }

    private func cleanupSmartMode() {
        pendingSendTimer?.cancel()
        pendingSendTimer = nil
    }

}
