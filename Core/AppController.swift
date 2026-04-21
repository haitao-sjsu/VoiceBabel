// AppController.swift
// VoiceBabel - macOS menu bar speech-to-text tool
//
// Core state machine and flow orchestrator. Manages recording lifecycle,
// dispatches to TranscriptionManager and TranslationManager, handles
// two-step translation orchestration (transcribe then translate).
//
// Responsibilities:
//   1. State machine: idle -> recording -> processing -> (waitingToSend ->) idle, error 3s auto-recovery
//   2. Recording lifecycle: begin / stop / cancel (single entry point beginRecording(mode:))
//   3. Availability preconditions: refuse to start when no engine is usable
//   4. Audio validation: min sample count + RMS threshold
//   5. Flow orchestration: transcription mode or two-step translation mode
//      via async/await on the Manager APIs — no callback plumbing
//   6. Result output: input text to active window, trigger auto-send
//
// Non-responsibilities (moved to Managers):
//   - Language resolution (TranscriptionManager / TranslationManager)
//   - Text post-processing (Managers apply TextPostProcessor before returning)
//   - Engine priority iteration and fallback (Managers)
//   - Timeouts and wire encoding (Services)
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
    private let textInputter: TextInputter

    // MARK: - State

    private(set) var currentState: AppState = .idle {
        didSet {
            onStateChange?(currentState)
        }
    }

    private var currentMode: RecordingMode = .transcribe
    let transcriptionManager: TranscriptionManager
    let translationManager: TranslationManager
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

    /// Swap in a freshly-built `CloudOpenAIService` (e.g. after the user updates
    /// the API key or model in Settings). Safe to call only in idle/error states
    /// to avoid pulling the rug out from under an in-flight request.
    func updateServices(cloudOpenAIService: CloudOpenAIService) {
        let lm = LocaleManager.shared
        guard currentState == .idle || currentState == .error else {
            Log.w(lm.logLocalized("AppController: current state") + " \(currentState) " + lm.logLocalized("does not allow service update"))
            return
        }
        self.transcriptionManager.cloudOpenAIService = cloudOpenAIService
        self.translationManager.cloudOpenAIService = cloudOpenAIService
    }

    // MARK: - Setup

    private func setupCallbacks() {
        audioRecorder.onMaxDurationReached = { [weak self] in
            self?.stopRecording()
        }
    }

    // MARK: - Public Methods

    /// Single entry point into the recording pipeline. Validates state, engine
    /// availability, and microphone availability before transitioning into
    /// `.recording`. Callers must not invoke any lower-level start method.
    func beginRecording(mode: RecordingMode) {
        let lm = LocaleManager.shared
        guard currentState == .idle || currentState == .error || currentState == .waitingToSend else {
            Log.i(lm.logLocalized("Cannot start recording, current state:") + " \(currentState)")
            return
        }

        // Availability preconditions — AppDelegate pre-filters `priority` lists
        // into the effective (enabled ∩ available) set, so emptiness here is the
        // single source of truth for "no engine usable right now".
        switch mode {
        case .transcribe:
            guard !transcriptionManager.priority.isEmpty else {
                Log.w("No transcription engine available (empty effective priority)")
                onError?(String(localized: "No transcription engine available. Check Settings."))
                return
            }
        case .translate:
            guard !transcriptionManager.priority.isEmpty else {
                Log.w("No transcription engine available (translation requires transcribe first)")
                onError?(String(localized: "No transcription engine available. Check Settings."))
                return
            }
            guard !translationManager.translationEnginePriority.isEmpty else {
                Log.w("No translation engine available (empty effective priority)")
                onError?(String(localized: "No translation engine available. Check Settings."))
                return
            }
        }

        // Mic availability
        if !audioRecorder.checkMicrophoneAvailability() {
            Log.i(lm.logLocalized("Microphone occupied"))
            handleError(String(localized: "Microphone is in use by another app"))
            return
        }

        if currentState == .error { currentState = .idle }
        currentMode = mode

        let modeText = mode == .transcribe ? lm.logLocalized("speech-to-text") : lm.logLocalized("speech translation")
        Log.i(lm.logLocalized("Starting recording") + " (\(modeText), priority=\(transcriptionManager.priority))...")

        autoSendManager.cancelDelayedSendForNewRecording()
        startNonStreamingRecording()
    }

    func toggleRecording(mode: RecordingMode) {
        let lm = LocaleManager.shared
        switch currentState {
        case .idle:
            beginRecording(mode: mode)
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

    /// Flat async/await flow: Manager call -> output. No callback nesting.
    /// Text is already post-processed by TranscriptionManager before return.
    private func startTranscription(samples: [Float], audioDuration: TimeInterval) {
        Task { @MainActor in
            do {
                let result = try await transcriptionManager.transcribe(samples: samples, audioDuration: audioDuration)
                guard !result.text.isEmpty else {
                    Log.i("Transcription result empty, skipping output")
                    currentState = .idle
                    return
                }
                Log.i("Transcription complete via \(result.engine): \(result.text)")
                onTranscriptionResult?(result.text, result.engine)
                textInputter.inputText(result.text)
                currentState = .idle
                autoSendManager.handleAutoSend()
            } catch {
                handleError(describeTranscriptionError(error))
            }
        }
    }

    private func describeTranscriptionError(_ error: Error) -> String {
        if let te = error as? TranscriptionError {
            return te.errorDescription ?? String(localized: "Transcription failed")
        }
        return String(localized: "Transcription failed: \(error.localizedDescription)")
    }

    // MARK: - Translation (Two-Step)

    /// Two-step flow: transcribe -> translate. Both steps are `await`ed
    /// sequentially in one `Task`, producing a flat control flow. If the
    /// transcription step returns empty text, skip translation entirely;
    /// if translation fails after a successful transcription, we log that the
    /// transcription is preserved in the menu bar (it was already emitted via
    /// `onTranscriptionResult`) before surfacing the translation error.
    private func startTranslation(samples: [Float], audioDuration: TimeInterval) {
        Task { @MainActor in
            do {
                let transcription = try await transcriptionManager.transcribe(samples: samples, audioDuration: audioDuration)
                guard !transcription.text.isEmpty else {
                    Log.i("Transcription empty; skipping translation step")
                    currentState = .idle
                    return
                }
                Log.i("Two-step translation step 1 complete via \(transcription.engine): \(transcription.text)")
                onTranscriptionResult?(transcription.text, transcription.engine)

                let translation = try await translationManager.translate(text: transcription.text)
                Log.i("Two-step translation step 2 complete via \(translation.engine): \(translation.text)")
                onTranslationResult?(translation.text, translation.engine)
                textInputter.inputText(translation.text)
                currentState = .idle
                autoSendManager.handleAutoSend()
            } catch let error as TranscriptionError {
                handleError(error.errorDescription ?? String(localized: "Transcription failed"))
            } catch let error as TranslationError {
                Log.i("Transcription preserved in menu bar (translation failed)")
                handleError(error.errorDescription ?? String(localized: "Translation failed"))
            } catch {
                handleError(error.localizedDescription)
            }
        }
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

}
