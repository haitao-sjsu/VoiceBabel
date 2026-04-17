// AppDelegate.swift
// WhisperUtil - macOS menu bar speech-to-text tool
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
    #if canImport(Translation)
    private var localAppleTranslationService: Any?  // LocalAppleTranslationService, type-erased for availability
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

        openaiApiKey = KeychainHelper.load() ?? ""
        Log.i(lm.logLocalized("Config:") + " model=\(EngineeringOptions.whisperModel), hotkey=Option key")

        setupComponents()

        let apiModeDescription: String
        switch settingsStore.transcriptionPriority.first {
        case "local": apiModeDescription = "Local (WhisperKit)"
        default:      apiModeDescription = "Cloud API (gpt-4o-transcribe)"
        }
        Log.i(lm.logLocalized("WhisperUtil started") + " — API mode: \(apiModeDescription), send mode: \(StatusBarController.AutoSendMode.from(settingsStore.autoSendMode).displayName)")

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
        Log.i(LocaleManager.shared.logLocalized("WhisperUtil quitting..."))
        hotkeyManager?.stopMonitoring()
    }

    // MARK: - Setup

    private func setupComponents() {
        let lm = LocaleManager.shared

        audioRecorder = AudioRecorder()
        textInputter = TextInputter()

        cloudOpenAIService = CloudOpenAIService(
            apiKey: openaiApiKey,
            model: EngineeringOptions.whisperModel,
            language: settingsStore.whisperLanguage
        )

        localWhisperService = LocalWhisperService(
            language: settingsStore.whisperLanguage
        )

        appController = AppController(
            audioRecorder: audioRecorder,
            cloudOpenAIService: cloudOpenAIService,
            localWhisperService: localWhisperService,
            textInputter: textInputter
        )

        // Apple Translation service (macOS 14.4+)
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let service = LocalAppleTranslationService()
            self.localAppleTranslationService = service
            appController.setLocalAppleTranslationService(service)
            Log.i(lm.logLocalized("Apple Translation service initialized"))
        }
        #endif

        appController.transcriptionManager.priority = settingsStore.transcriptionPriority
        if let topEngine = settingsStore.transcriptionPriority.first {
            appController.transcriptionManager.userDidChangePreferredEngine(topEngine)
        }
        appController.translationManager.translationEnginePriority = settingsStore.translationEnginePriority

        networkHealthMonitor = NetworkHealthMonitor(apiKey: openaiApiKey)
        networkHealthMonitor.onCloudRecovered = { [weak self] in
            guard let self = self else { return }
            self.appController.recoverFromFallback()
            self.statusBarController.setApiMode(self.appController.currentApiMode)
            self.statusBarController.updateState(self.appController.currentState)
            self.statusBarController.showNotification(title: "WhisperUtil", message: String(localized: "Network recovered, switched back to Cloud API"))
        }

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

        statusBarController = StatusBarController(apiMode: appController.currentApiMode)

        settingsWindowController = SettingsWindowController(settingsStore: settingsStore)
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

        // Combine subscriptions for settings changes
        settingsStore.$transcriptionPriority.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] priority in
            guard let self = self else { return }
            self.appController.transcriptionManager.priority = priority
            if let topEngine = priority.first {
                self.appController.transcriptionManager.userDidChangePreferredEngine(topEngine)
            }
            self.statusBarController.setApiMode(self.appController.currentApiMode)
            Log.i(lm.logLocalized("Settings: Transcription priority changed to") + " \(priority)")
        }.store(in: &cancellables)

        settingsStore.$translationEnginePriority.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] priority in
            self?.appController.translationManager.translationEnginePriority = priority
            Log.i(lm.logLocalized("Settings: Translation engine priority changed to") + " \(priority)")
        }.store(in: &cancellables)

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

        settingsStore.$whisperLanguage.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] lang in
            self?.updateServicesLanguage(lang)
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
        appController.onTranscriptionResult = { [weak self] text, _ in
            self?.statusBarController.setLastTranscription(text)
        }
        appController.onTranslationResult = { [weak self] text, _ in
            self?.statusBarController.setLastTranslation(text)
        }
        appController.onError = { [weak self] message in
            guard let self = self else { return }
            self.statusBarController.showNotification(title: "WhisperUtil", message: message)

            if self.appController.isInFallbackMode && !self.networkHealthMonitor.isMonitoring {
                self.statusBarController.setApiMode(.local)
                self.networkHealthMonitor.startMonitoring()
            }
        }

        statusBarController.updateState(.idle)
    }

    // MARK: - Language Change

    private func updateServicesLanguage(_ lang: String) {
        cloudOpenAIService.language = lang
        localWhisperService.language = lang
    }

    // MARK: - API Key Change

    private func rebuildServicesWithNewApiKey() {
        let lm = LocaleManager.shared
        let newKey = KeychainHelper.load() ?? ""

        if newKey.isEmpty {
            Log.w(lm.logLocalized("API Key cleared, network features unavailable"))
            if appController.currentApiMode != .local {
                appController.userDidChangeApiMode(.local)
                statusBarController.setApiMode(.local)
                statusBarController.showNotification(
                    title: "WhisperUtil",
                    message: String(localized: "API Key cleared, switched to local mode")
                )
            }
            return
        }

        cloudOpenAIService = CloudOpenAIService(
            apiKey: newKey,
            model: EngineeringOptions.whisperModel,
            language: settingsStore.whisperLanguage
        )
        networkHealthMonitor = NetworkHealthMonitor(apiKey: newKey)

        appController.updateServices(
            cloudOpenAIService: cloudOpenAIService
        )

        let topPriority = settingsStore.transcriptionPriority.first ?? "cloud"
        let preferredMode: StatusBarController.ApiMode = (topPriority == "local") ? .local : .cloud
        appController.userDidChangeApiMode(preferredMode)
        statusBarController.setApiMode(preferredMode)

        Log.i(lm.logLocalized("API Key updated, services rebuilt, mode restored to") + " \(topPriority)")
        statusBarController.showNotification(
            title: "WhisperUtil",
            message: String(localized: "API Key updated")
        )
    }

}
