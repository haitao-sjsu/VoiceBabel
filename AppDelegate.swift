// AppDelegate.swift
// VoiceBabel - macOS menu bar speech-to-text tool
//
// Composition Root — initializes all components and connects them via callbacks.
//
// Responsibilities:
//   1. Load API keys (KeychainHelper.load() <- Keychain)
//   2. Create and connect all components
//   3. Subscribe to SettingsStore changes via Combine, propagate to components
//   4. Async preload WhisperKit local model
//   5. Manage app lifecycle (graceful quit: wait for recording/processing to finish)
//
// Dependencies:
//   - KeychainHelper, SettingsStore, LocaleManager
//   - AudioRecorder, Services, AppController
//   - StatusBarController, SettingsWindowController
//   - HotkeyManager, NetworkHealthMonitor, TextInputter

import Cocoa
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private var statusBarController: StatusBarController!
    private var appController: AppController!
    private var audioRecorder: AudioRecorder!
    private var cloudOpenAIService: CloudOpenAIService!
    private var localWhisperService: LocalWhisperService!
    private var textInputter: TextInputter!
    private var hotkeyManager: HotkeyManager!
    private var openaiApiKey: String = ""
    private var networkHealthMonitor: NetworkHealthMonitor!
    private var settingsStore: SettingsStore!
    private var settingsWindowController: SettingsWindowController!
    // Objective-availability probe. Implicitly unwrapped because it needs dependencies
    // (translationManager.localTranslator) that only exist after setupComponents() runs.
    private var probe: EngineAvailabilityProbe!
    private var cancellables = Set<AnyCancellable>()

    private var isPushToTalkActive = false
    private var pendingQuit = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 测试环境下跳过完整初始化（避免 AVAudioEngine 等硬件依赖在测试退出时 crash）
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        let lm = LocaleManager.shared
        Log.i(lm.logLocalized("VoiceBabel starting..."))
        Log.i(lm.logLocalized("Log file path:") + " \(Log.logFilePath)")

        settingsStore = SettingsStore.shared

        openaiApiKey = KeychainHelper.load() ?? ""
        Log.i(lm.logLocalized("Config:") + " model=\(EngineeringOptions.whisperModel), hotkey=Option key")

        setupComponents()

        let apiModeDescription: String
        switch settingsStore.transcriptionPriority.first {
        case "local": apiModeDescription = "Local (WhisperKit)"
        default:      apiModeDescription = "Cloud API (gpt-4o-transcribe)"
        }
        Log.i(lm.logLocalized("VoiceBabel started") + " — API mode: \(apiModeDescription), send mode: \(StatusBarController.AutoSendMode.from(settingsStore.autoSendMode).displayName)")

        // Async preload WhisperKit model
        statusBarController.showNotification(title: "WhisperKit", message: String(localized: "Loading speech recognition model, first use requires download..."))
        Task {
            do {
                try await localWhisperService.loadModel()
                Log.i(lm.logLocalized("WhisperKit model preload complete"))
                await MainActor.run {
                    statusBarController.showNotification(title: "WhisperKit", message: String(localized: "Model loaded, local recognition ready"))
                }
            } catch {
                Log.e(lm.logLocalized("WhisperKit model preload failed:") + " \(error.localizedDescription)")
                await MainActor.run {
                    statusBarController.showNotification(title: "WhisperKit", message: String(localized: "Model loading failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let lm = LocaleManager.shared
        let state = appController.currentState
        if state == .idle || state == .error {
            Log.i(lm.logLocalized("Quit requested, currently idle, quitting now"))
            return .terminateNow
        }
        Log.i(lm.logLocalized("Quit requested, current state:") + " \(state)" + lm.logLocalized(", waiting for completion..."))
        pendingQuit = true
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.i(LocaleManager.shared.logLocalized("VoiceBabel quitting..."))
        hotkeyManager?.stopMonitoring()
    }

    // MARK: - Setup

    private func setupComponents() {
        let lm = LocaleManager.shared

        audioRecorder = AudioRecorder()
        textInputter = TextInputter()

        cloudOpenAIService = CloudOpenAIService(
            apiKey: openaiApiKey,
            model: EngineeringOptions.whisperModel
        )

        localWhisperService = LocalWhisperService()

        appController = AppController(
            audioRecorder: audioRecorder,
            cloudOpenAIService: cloudOpenAIService,
            localWhisperService: localWhisperService,
            textInputter: textInputter
        )

        // On-device translation — factory handles the macOS 15+ gate.
        if let translator = LocalTranslatorFactory.make() {
            appController.translationManager.localTranslator = translator
            Log.i(lm.logLocalized("Apple Translation service initialized"))
        }

        // Manager priorities are pushed by the merged CombineLatest sinks below — no manual
        // initial assignment here (that would push the *unfiltered* list and get overwritten
        // microseconds later).

        // NetworkHealthMonitor instance retained but unwired — recoverFromFallback / isInFallbackMode
        // no longer exist after the engine-priority refactor. File flagged as dead code for follow-up PR.
        networkHealthMonitor = NetworkHealthMonitor(apiKey: openaiApiKey)

        appController.autoSendManager.autoSendMode = StatusBarController.AutoSendMode.from(settingsStore.autoSendMode)
        appController.autoSendManager.delayedSendDuration = settingsStore.delayedSendDuration

        hotkeyManager = HotkeyManager()
        hotkeyManager.onPushToTalkStart = { [weak self] in
            guard let self = self else { return }
            guard self.appController.currentState == .idle ||
                  self.appController.currentState == .error ||
                  self.appController.currentState == .waitingToSend else {
                return
            }
            self.isPushToTalkActive = true
            self.appController.beginRecording(mode: .transcribe)
        }
        hotkeyManager.onPushToTalkStop = { [weak self] in
            guard let self = self else { return }
            guard self.isPushToTalkActive else { return }
            self.isPushToTalkActive = false
            self.appController.stopRecording()
        }
        hotkeyManager.onSingleTap = { [weak self] in
            self?.isPushToTalkActive = false
            self?.appController.toggleRecording(mode: .transcribe)
        }
        hotkeyManager.onDoubleTap = { [weak self] in
            self?.isPushToTalkActive = false
            self?.appController.toggleRecording(mode: .translate)
        }
        hotkeyManager.onEscPressed = { [weak self] in
            self?.isPushToTalkActive = false
            self?.appController.cancelRecording()
        }
        hotkeyManager.startMonitoring()

        // Construct the availability probe once dependencies exist. It reads live state;
        // AppDelegate's merged Combine sinks trigger re-evaluation on change.
        probe = EngineAvailabilityProbe(
            settingsStore: settingsStore,
            localWhisperService: localWhisperService,
            localTranslator: { [weak self] in self?.appController.translationManager.localTranslator }
        )

        statusBarController = StatusBarController()

        settingsWindowController = SettingsWindowController(settingsStore: settingsStore, localWhisperService: localWhisperService, probe: probe)
        statusBarController.onOpenSettings = { [weak self] in
            self?.settingsWindowController.showSettings()
        }

        statusBarController.onTranscribeToggle = { [weak self] in
            self?.appController.toggleRecording(mode: .transcribe)
        }
        statusBarController.onTranslateToggle = { [weak self] in
            self?.appController.toggleRecording(mode: .translate)
        }
        statusBarController.onQuit = {
            NSApplication.shared.terminate(nil)
        }

        // Merged subscriptions — effective priority = priority ∩ subjective-enabled ∩ objectively-available.
        // CombineLatest fires once with current values on subscribe, then on any change, so the Managers
        // get the correctly-filtered list without needing a manual initial push.
        Publishers.CombineLatest4(
            settingsStore.$transcriptionPriority,
            settingsStore.$transcriptionEnabled,
            settingsStore.$apiKeyVersion,
            localWhisperService.$state
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _, _ in
            guard let self = self else { return }
            let effective = self.effectiveTranscriptionPriority()
            self.appController.transcriptionManager.priority = effective
            Log.i(lm.logLocalized("Effective transcription priority:") + " \(effective)")
        }
        .store(in: &cancellables)

        Publishers.CombineLatest3(
            settingsStore.$translationEnginePriority,
            settingsStore.$translationEngineEnabled,
            settingsStore.$apiKeyVersion
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _ in
            guard let self = self else { return }
            let effective = self.effectiveTranslationPriority()
            self.appController.translationManager.translationEnginePriority = effective
            Log.i(lm.logLocalized("Effective translation priority:") + " \(effective)")
        }
        .store(in: &cancellables)

        settingsStore.$autoSendMode.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] modeString in
            self?.appController.autoSendManager.autoSendMode = StatusBarController.AutoSendMode.from(modeString)
            Log.i(lm.logLocalized("Settings: Send mode changed to") + " \(modeString)")
        }.store(in: &cancellables)

        settingsStore.$delayedSendDuration.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] duration in
            self?.appController.autoSendManager.delayedSendDuration = duration
            Log.i(lm.logLocalized("Settings: Delay changed to") + " \(Int(duration))s")
        }.store(in: &cancellables)

        settingsStore.$playSound.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.appController.playSound = value
            Log.i(lm.logLocalized("Settings: Sound effects") + " \(value ? "on" : "off")")
        }.store(in: &cancellables)

        settingsStore.$whisperLanguage.dropFirst().receive(on: DispatchQueue.main).sink { lang in
            // Language is resolved per-call inside TranscriptionManager; services no longer mirror it.
            Log.i(lm.logLocalized("Settings: Recognition language changed to") + " \(lang.isEmpty ? "auto" : lang)")
        }.store(in: &cancellables)

        settingsStore.$apiKeyVersion.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.rebuildServicesWithNewApiKey()
        }.store(in: &cancellables)

        appController.onStateChange = { [weak self] state in
            self?.statusBarController.updateState(state)
            if self?.pendingQuit == true && (state == .idle || state == .error) {
                Log.i(lm.logLocalized("Processing complete, executing delayed quit"))
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
        appController.onTranscriptionResult = { [weak self] text, engine in
            self?.statusBarController.setLastTranscription(text)
            self?.statusBarController.setLastTranscriptionEngine(engine)
        }
        appController.onTranslationResult = { [weak self] text, engine in
            self?.statusBarController.setLastTranslation(text)
            self?.statusBarController.setLastTranslationEngine(engine)
        }
        appController.onError = { [weak self] message in
            guard let self = self else { return }
            self.statusBarController.showNotification(title: "VoiceBabel", message: message)
        }

        statusBarController.updateState(.idle)
    }

    // MARK: - Effective Priority (subjective × objective filter)

    /// Transcription priority minus engines the user disabled minus engines the probe
    /// reports objectively unavailable. This is what Managers see at call time.
    private func effectiveTranscriptionPriority() -> [String] {
        settingsStore.transcriptionPriority
            .filter { settingsStore.transcriptionEnabled[$0] ?? true }
            .filter { probe.availability(ofTranscriptionEngine: $0) == .available }
    }

    /// Translation priority minus engines the user disabled minus engines the probe
    /// reports objectively unavailable. This is what Managers see at call time.
    private func effectiveTranslationPriority() -> [String] {
        settingsStore.translationEnginePriority
            .filter { settingsStore.translationEngineEnabled[$0] ?? true }
            .filter { probe.availability(ofTranslationEngine: $0) == .available }
    }

    // MARK: - API Key Change

    private func rebuildServicesWithNewApiKey() {
        let lm = LocaleManager.shared
        let newKey = KeychainHelper.load() ?? ""

        if newKey.isEmpty {
            Log.w(lm.logLocalized("API Key cleared, network features unavailable"))
            // Effective-priority sinks re-fire automatically via $apiKeyVersion.
            statusBarController.showNotification(
                title: "VoiceBabel",
                message: String(localized: "API Key cleared, switched to local mode")
            )
            return
        }

        cloudOpenAIService = CloudOpenAIService(
            apiKey: newKey,
            model: EngineeringOptions.whisperModel
        )
        networkHealthMonitor = NetworkHealthMonitor(apiKey: newKey)

        appController.updateServices(
            cloudOpenAIService: cloudOpenAIService
        )

        Log.i(lm.logLocalized("API Key updated, services rebuilt, top priority") + " \(settingsStore.transcriptionPriority.first ?? "cloud")")
        statusBarController.showNotification(
            title: "VoiceBabel",
            message: String(localized: "API Key updated")
        )
    }

}
