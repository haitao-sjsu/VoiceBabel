// AppDelegate.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Composition Root — initializes all components and connects them via callbacks.
//
// Responsibilities:
//   1. Load runtime config (Config.load() <- UserSettings + EngineeringOptions)
//   2. Create and connect all components
//   3. Subscribe to SettingsStore changes via Combine, propagate to components
//   4. Async preload WhisperKit local model
//   5. Manage app lifecycle (graceful quit: wait for recording/processing to finish)
//
// Dependencies:
//   - Config, SettingsStore, LocaleManager
//   - AudioRecorder, Services, RecordingController
//   - StatusBarController, SettingsWindowController
//   - HotkeyManager, NetworkHealthMonitor, TextInputter

import Cocoa
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private var statusBarController: StatusBarController!
    private var recordingController: RecordingController!
    private var audioRecorder: AudioRecorder!
    private var whisperService: ServiceCloudOpenAI!
    private var realtimeService: ServiceRealtimeOpenAI!
    private var localWhisperService: ServiceLocalWhisper!
    private var textInputter: TextInputter!
    private var hotkeyManager: HotkeyManager!
    private var config: Config!
    private var textCleanupService: ServiceTextCleanup!
    private var networkHealthMonitor: NetworkHealthMonitor!
    private var settingsStore: SettingsStore!
    private var settingsWindowController: SettingsWindowController!
    #if canImport(Translation)
    private var appleTranslationService: Any?  // ServiceAppleTranslation, type-erased for availability
    #endif
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
        Log.i(lm.logLocalized("WhisperUtil starting..."))
        Log.i(lm.logLocalized("Log file path:") + " \(Log.logFilePath)")

        settingsStore = SettingsStore.shared

        config = Config.load()
        Log.i(lm.logLocalized("Config:") + " model=\(config.whisperModel), hotkey=Option gesture")

        setupComponents()

        let apiModeDescription: String
        switch config.defaultApiMode {
        case "realtime": apiModeDescription = "Realtime (WebSocket)"
        case "cloud":    apiModeDescription = "Cloud API (gpt-4o-transcribe)"
        default:         apiModeDescription = "Local (WhisperKit)"
        }
        Log.i(lm.logLocalized("WhisperUtil started") + " — API mode: \(apiModeDescription), send mode: \(StatusBarController.AutoSendMode.from(config.autoSendMode).displayName)")

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
        let state = recordingController.currentState
        if state == .idle || state == .error {
            Log.i(lm.logLocalized("Quit requested, currently idle, quitting now"))
            return .terminateNow
        }
        Log.i(lm.logLocalized("Quit requested, current state:") + " \(state)" + lm.logLocalized(", waiting for completion..."))
        pendingQuit = true
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.i(LocaleManager.shared.logLocalized("WhisperUtil quitting..."))
        hotkeyManager?.stopMonitoring()
    }

    // MARK: - Setup

    private func setupComponents() {
        let lm = LocaleManager.shared

        audioRecorder = AudioRecorder()
        textInputter = TextInputter()

        whisperService = ServiceCloudOpenAI(
            apiKey: config.openaiApiKey,
            model: config.whisperModel,
            language: config.whisperLanguage
        )

        realtimeService = ServiceRealtimeOpenAI(
            apiKey: config.openaiApiKey,
            language: config.whisperLanguage
        )

        localWhisperService = ServiceLocalWhisper(
            language: config.whisperLanguage
        )

        textCleanupService = ServiceTextCleanup(
            apiKey: config.openaiApiKey
        )

        recordingController = RecordingController(
            audioRecorder: audioRecorder,
            whisperService: whisperService,
            realtimeService: realtimeService,
            localWhisperService: localWhisperService,
            textInputter: textInputter,
            textCleanupService: textCleanupService,
            config: config
        )

        // Apple Translation service (macOS 14.4+)
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let service = ServiceAppleTranslation()
            self.appleTranslationService = service
            recordingController.setAppleTranslationService(service)
            Log.i(lm.logLocalized("Apple Translation service initialized"))
        }
        #endif

        let defaultMode: StatusBarController.ApiMode
        switch config.defaultApiMode {
        case "realtime": defaultMode = .realtime
        case "cloud":    defaultMode = .cloud
        default:         defaultMode = .local
        }
        recordingController.preferredApiMode = defaultMode
        recordingController.currentApiMode = defaultMode

        networkHealthMonitor = NetworkHealthMonitor(apiKey: config.openaiApiKey)
        networkHealthMonitor.onCloudRecovered = { [weak self] in
            guard let self = self else { return }
            self.recordingController.recoverFromFallback()
            self.statusBarController.setApiMode(self.recordingController.currentApiMode)
            self.statusBarController.updateState(self.recordingController.currentState)
            self.statusBarController.showNotification(title: "WhisperUtil", message: String(localized: "Network recovered, switched back to Cloud API"))
        }

        recordingController.autoSendMode = StatusBarController.AutoSendMode.from(config.autoSendMode)
        recordingController.smartModeWaitDuration = config.smartModeWaitDuration
        recordingController.textCleanupMode = TextCleanupMode.from(config.textCleanupMode)

        hotkeyManager = HotkeyManager()
        hotkeyManager.onPushToTalkStart = { [weak self] in
            guard let self = self else { return }
            guard self.recordingController.currentState == .idle ||
                  self.recordingController.currentState == .error ||
                  self.recordingController.currentState == .waitingToSend else {
                return
            }
            self.isPushToTalkActive = true
            self.recordingController.beginRecording(mode: .transcribe)
        }
        hotkeyManager.onPushToTalkStop = { [weak self] in
            guard let self = self else { return }
            guard self.isPushToTalkActive else { return }
            self.isPushToTalkActive = false
            self.recordingController.stopRecording()
        }
        hotkeyManager.onSingleTap = { [weak self] in
            self?.isPushToTalkActive = false
            self?.recordingController.toggleRecording(mode: .transcribe)
        }
        hotkeyManager.onDoubleTap = { [weak self] in
            self?.isPushToTalkActive = false
            self?.recordingController.toggleRecording(mode: .translate)
        }
        hotkeyManager.onEscPressed = { [weak self] in
            self?.isPushToTalkActive = false
            self?.recordingController.cancelRecording()
        }
        hotkeyManager.startMonitoring()

        statusBarController = StatusBarController(apiMode: recordingController.currentApiMode)

        settingsWindowController = SettingsWindowController(settingsStore: settingsStore)
        statusBarController.onOpenSettings = { [weak self] in
            self?.settingsWindowController.showSettings()
        }

        statusBarController.onTranscribeToggle = { [weak self] in
            self?.recordingController.toggleRecording(mode: .transcribe)
        }
        statusBarController.onTranslateToggle = { [weak self] in
            self?.recordingController.toggleRecording(mode: .translate)
        }
        statusBarController.onQuit = {
            NSApplication.shared.terminate(nil)
        }

        // Combine subscriptions for settings changes
        settingsStore.$defaultApiMode.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] modeString in
            guard let self = self else { return }
            let mode: StatusBarController.ApiMode
            switch modeString {
            case "realtime": mode = .realtime
            case "cloud": mode = .cloud
            default: mode = .local
            }
            self.recordingController.userDidChangeApiMode(mode)
            self.networkHealthMonitor.stopMonitoring()
            self.statusBarController.setApiMode(mode)
            Log.i(lm.logLocalized("Settings: API mode changed to") + " \(modeString)")
        }.store(in: &cancellables)

        settingsStore.$autoSendMode.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] modeString in
            self?.recordingController.autoSendMode = StatusBarController.AutoSendMode.from(modeString)
            Log.i(lm.logLocalized("Settings: Send mode changed to") + " \(modeString)")
        }.store(in: &cancellables)

        settingsStore.$smartModeWaitDuration.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] duration in
            self?.recordingController.smartModeWaitDuration = duration
            Log.i(lm.logLocalized("Settings: Delay changed to") + " \(Int(duration))s")
        }.store(in: &cancellables)

        settingsStore.$textCleanupMode.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] modeString in
            self?.recordingController.textCleanupMode = TextCleanupMode(rawValue: modeString) ?? .off
            Log.i(lm.logLocalized("Settings: Text cleanup changed to") + " \(modeString)")
        }.store(in: &cancellables)

        settingsStore.$playSound.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.recordingController.playSound = value
            Log.i(lm.logLocalized("Settings: Sound effects") + " \(value ? "on" : "off")")
        }.store(in: &cancellables)

        settingsStore.$whisperLanguage.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] lang in
            self?.updateServicesLanguage(lang)
            Log.i(lm.logLocalized("Settings: Recognition language changed to") + " \(lang.isEmpty ? "auto" : lang)")
        }.store(in: &cancellables)

        settingsStore.$apiKeyVersion.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.rebuildServicesWithNewApiKey()
        }.store(in: &cancellables)

        recordingController.onStateChange = { [weak self] state in
            self?.statusBarController.updateState(state)
            if self?.pendingQuit == true && (state == .idle || state == .error) {
                Log.i(lm.logLocalized("Processing complete, executing delayed quit"))
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
        recordingController.onTranscriptionResult = { [weak self] text in
            self?.statusBarController.setLastTranscription(text)
        }
        recordingController.onTranslationResult = { [weak self] text in
            self?.statusBarController.setLastTranslation(text)
        }
        recordingController.onError = { [weak self] message in
            guard let self = self else { return }
            self.statusBarController.showNotification(title: "WhisperUtil", message: message)

            if self.recordingController.isInFallbackMode && !self.networkHealthMonitor.isMonitoring {
                self.statusBarController.setApiMode(.local)
                self.networkHealthMonitor.startMonitoring()
            }
        }

        statusBarController.updateState(.idle)
    }

    // MARK: - Language Change

    private func updateServicesLanguage(_ lang: String) {
        whisperService.language = lang
        realtimeService.language = lang
        localWhisperService.language = lang
    }

    // MARK: - API Key Change

    private func rebuildServicesWithNewApiKey() {
        let lm = LocaleManager.shared
        let newKey = KeychainHelper.load() ?? ""

        if newKey.isEmpty {
            Log.w(lm.logLocalized("API Key cleared, network features unavailable"))
            if recordingController.currentApiMode != .local {
                recordingController.userDidChangeApiMode(.local)
                statusBarController.setApiMode(.local)
                statusBarController.showNotification(
                    title: "WhisperUtil",
                    message: String(localized: "API Key cleared, switched to local mode")
                )
            }
            return
        }

        whisperService = ServiceCloudOpenAI(
            apiKey: newKey,
            model: config.whisperModel,
            language: settingsStore.whisperLanguage
        )
        realtimeService = ServiceRealtimeOpenAI(
            apiKey: newKey,
            language: settingsStore.whisperLanguage
        )
        textCleanupService = ServiceTextCleanup(apiKey: newKey)
        networkHealthMonitor = NetworkHealthMonitor(apiKey: newKey)

        recordingController.updateServices(
            whisperService: whisperService,
            realtimeService: realtimeService,
            textCleanupService: textCleanupService
        )

        let preferredMode: StatusBarController.ApiMode
        switch settingsStore.defaultApiMode {
        case "realtime": preferredMode = .realtime
        case "cloud":    preferredMode = .cloud
        default:         preferredMode = .local
        }
        recordingController.userDidChangeApiMode(preferredMode)
        statusBarController.setApiMode(preferredMode)

        Log.i(lm.logLocalized("API Key updated, services rebuilt, mode restored to") + " \(settingsStore.defaultApiMode)")
        statusBarController.showNotification(
            title: "WhisperUtil",
            message: String(localized: "API Key updated")
        )
    }

}
