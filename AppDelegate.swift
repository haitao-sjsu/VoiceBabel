// AppDelegate.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 组合根（Composition Root）—— 应用程序委托，负责初始化所有组件并通过回调连接。
//
// 职责：
//   1. 加载运行时配置（Config.load() ← UserSettings + EngineeringOptions）
//   2. 创建并连接所有组件：AudioRecorder、各 Service、RecordingController、
//      StatusBarController、HotkeyManager、NetworkHealthMonitor、SettingsWindowController
//   3. 通过 Combine 订阅 SettingsStore 的 @Published 属性，实时将设置变更传播到各组件
//   4. 异步预加载 WhisperKit 本地模型
//   5. 管理应用生命周期（优雅退出：等待录音/处理完成后再退出）
//
// 组件连接方式：
//   - HotkeyManager → RecordingController（通过闭包回调触发录音开始/停止/切换/取消）
//   - RecordingController → StatusBarController（通过 onStateChange/onError 回调更新 UI）
//   - SettingsStore → RecordingController/StatusBarController（通过 Combine $publisher 实时更新）
//   - NetworkHealthMonitor → RecordingController/StatusBarController（通过 onCloudRecovered 回调恢复网络模式）
//
// 依赖：
//   - Config, SettingsStore：配置管理
//   - AudioRecorder：音频采集
//   - ServiceCloudOpenAI, ServiceRealtimeOpenAI, ServiceLocalWhisper, ServiceTextCleanup：转写后端
//   - RecordingController：核心状态机
//   - StatusBarController, SettingsWindowController：UI
//   - HotkeyManager：快捷键
//   - NetworkHealthMonitor：网络恢复探测
//   - TextInputter：文字输入

import Cocoa
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - 组件

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
    private var cancellables = Set<AnyCancellable>()

    /// 标记当前录音是否由 Push-to-Talk 触发（用于区分 PTT 和双击模式）
    private var isPushToTalkActive = false

    /// 标记是否有待处理的退出请求（等待录音/处理完成后退出）
    private var pendingQuit = false

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.i("WhisperUtil 启动中...")
        Log.i("日志文件路径: \(Log.logFilePath)")

        settingsStore = SettingsStore.shared

        config = Config.load()
        Log.i("配置: 模型=\(config.whisperModel), 快捷键=Option键手势")

        setupComponents()

        let apiModeDescription: String
        switch config.defaultApiMode {
        case "realtime": apiModeDescription = "实时 (WebSocket)"
        case "cloud":    apiModeDescription = "网络 API (gpt-4o-transcribe)"
        default:         apiModeDescription = "本地识别 (WhisperKit)"
        }
        Log.i("WhisperUtil 已启动 — API模式: \(apiModeDescription), 发送模式: \(StatusBarController.AutoSendMode.from(config.autoSendMode).displayName)")

        // 异步预加载本地 WhisperKit 模型
        statusBarController.showNotification(title: "WhisperKit", message: "正在加载语音识别模型，首次使用需下载...")
        Task {
            do {
                try await localWhisperService.loadModel()
                Log.i("WhisperKit 模型预加载完成")
                await MainActor.run {
                    statusBarController.showNotification(title: "WhisperKit", message: "模型加载完成，本地识别已就绪")
                }
            } catch {
                Log.e("WhisperKit 模型预加载失败: \(error.localizedDescription)")
                await MainActor.run {
                    statusBarController.showNotification(title: "WhisperKit", message: "模型加载失败: \(error.localizedDescription)")
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = recordingController.currentState
        if state == .idle || state == .error {
            Log.i("收到退出请求，当前空闲，立即退出")
            return .terminateNow
        }
        // Recording or processing in progress — wait for completion
        Log.i("收到退出请求，当前状态: \(state)，等待完成后退出...")
        pendingQuit = true
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.i("WhisperUtil 正在退出...")
        hotkeyManager?.stopMonitoring()
    }

    // MARK: - 初始化

    private func setupComponents() {
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

        // 设置默认 API 模式
        let defaultMode: StatusBarController.ApiMode
        switch config.defaultApiMode {
        case "realtime": defaultMode = .realtime
        case "cloud":    defaultMode = .cloud
        default:         defaultMode = .local
        }
        recordingController.preferredApiMode = defaultMode
        recordingController.currentApiMode = defaultMode

        // 初始化网络健康探测器
        networkHealthMonitor = NetworkHealthMonitor(apiKey: config.openaiApiKey)
        networkHealthMonitor.onCloudRecovered = { [weak self] in
            guard let self = self else { return }
            self.recordingController.recoverFromFallback()
            // fallback 模式 UI 已通过 setApiMode 处理
            self.statusBarController.setApiMode(self.recordingController.currentApiMode)
            self.statusBarController.updateState(self.recordingController.currentState)
            self.statusBarController.showNotification(title: "WhisperUtil", message: "网络已恢复，已切回网络 API")
        }

        // 网络回退时的探测启动逻辑在 onError 回调中处理
        recordingController.autoSendMode = StatusBarController.AutoSendMode.from(config.autoSendMode)
        recordingController.smartModeWaitDuration = config.smartModeWaitDuration
        recordingController.textCleanupMode = TextCleanupMode.from(config.textCleanupMode)

        // 初始化快捷键管理器（Option 键手势）
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

        // 初始化菜单栏（简化：只需 API 模式）
        statusBarController = StatusBarController(apiMode: recordingController.currentApiMode)

        // 创建设置窗口
        settingsWindowController = SettingsWindowController(settingsStore: settingsStore)
        statusBarController.onOpenSettings = { [weak self] in
            self?.settingsWindowController.showSettings()
        }

        // 设置菜单栏回调
        statusBarController.onTranscribeToggle = { [weak self] in
            self?.recordingController.toggleRecording(mode: .transcribe)
        }
        statusBarController.onTranslateToggle = { [weak self] in
            self?.recordingController.toggleRecording(mode: .translate)
        }
        statusBarController.onQuit = {
            NSApplication.shared.terminate(nil)
        }

        // Combine 监听设置变更
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
            // fallback 模式 UI 已通过 setApiMode 处理
            self.statusBarController.setApiMode(mode)
            Log.i("设置: API 模式切换为 \(modeString)")
        }.store(in: &cancellables)

        settingsStore.$autoSendMode.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] modeString in
            self?.recordingController.autoSendMode = StatusBarController.AutoSendMode.from(modeString)
            Log.i("设置: 发送模式切换为 \(modeString)")
        }.store(in: &cancellables)

        settingsStore.$smartModeWaitDuration.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] duration in
            self?.recordingController.smartModeWaitDuration = duration
            Log.i("设置: 延迟时间切换为 \(Int(duration))秒")
        }.store(in: &cancellables)

        settingsStore.$textCleanupMode.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] modeString in
            self?.recordingController.textCleanupMode = TextCleanupMode(rawValue: modeString) ?? .off
            Log.i("设置: 文本优化切换为 \(modeString)")
        }.store(in: &cancellables)

        settingsStore.$playSound.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.recordingController.playSound = value
            Log.i("设置: 提示音 \(value ? "开启" : "关闭")")
        }.store(in: &cancellables)

        settingsStore.$apiKeyVersion.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.rebuildServicesWithNewApiKey()
        }.store(in: &cancellables)

        // 设置录音控制器回调
        recordingController.onStateChange = { [weak self] state in
            self?.statusBarController.updateState(state)
            // Check if we have a pending quit request and the app is now idle
            if self?.pendingQuit == true && (state == .idle || state == .error) {
                Log.i("处理完成，执行延迟退出")
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
        recordingController.onTranscriptionResult = { [weak self] text in
            self?.statusBarController.setLastTranscription(text)
        }
        recordingController.onError = { [weak self] message in
            guard let self = self else { return }
            self.statusBarController.showNotification(title: "WhisperUtil", message: message)

            // 进入回退模式时，更新菜单栏显示并启动网络探测
            if self.recordingController.isInFallbackMode && !self.networkHealthMonitor.isMonitoring {
                self.statusBarController.setApiMode(.local)
                // fallback 模式 UI 已通过 setApiMode(.local) 处理
                self.networkHealthMonitor.startMonitoring()
            }
        }

        statusBarController.updateState(.idle)
    }

    // MARK: - API Key 变更

    /// 当 API Key 变更时重建所有依赖 API Key 的服务
    private func rebuildServicesWithNewApiKey() {
        let newKey = KeychainHelper.load() ?? ""

        if newKey.isEmpty {
            Log.w("API Key 已清除，网络功能将不可用")
            // 如果当前是网络模式，自动切换到本地模式
            if recordingController.currentApiMode != .local {
                recordingController.userDidChangeApiMode(.local)
                statusBarController.setApiMode(.local)
                statusBarController.showNotification(
                    title: "WhisperUtil",
                    message: "API Key 已清除，已切换到本地识别模式"
                )
            }
            return
        }

        // 重建服务
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

        // 重新注入到 RecordingController
        recordingController.updateServices(
            whisperService: whisperService,
            realtimeService: realtimeService,
            textCleanupService: textCleanupService
        )

        // 恢复用户偏好的 API 模式
        let preferredMode: StatusBarController.ApiMode
        switch settingsStore.defaultApiMode {
        case "realtime": preferredMode = .realtime
        case "cloud":    preferredMode = .cloud
        default:         preferredMode = .local
        }
        recordingController.userDidChangeApiMode(preferredMode)
        statusBarController.setApiMode(preferredMode)

        Log.i("API Key 已更新，服务已重建，模式恢复为 \(settingsStore.defaultApiMode)")
        statusBarController.showNotification(
            title: "WhisperUtil",
            message: "API Key 已更新"
        )
    }

}
