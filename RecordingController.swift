// RecordingController.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 核心调度器 —— 整个应用的中枢控制器，管理录音状态机并协调所有转写后端。
//
// 职责：
//   1. 状态机管理：idle → recording → processing → (waitingToSend →) idle，error 3s 自动恢复
//   2. API 模式路由：根据用户选择的模式（local/cloud/realtime）调用对应的录音和转写流程
//   3. 翻译支持：Whisper API 直接翻译 和 两步法（转录+GPT翻译），由 EngineeringOptions.translationMethod 控制
//   4. 文本优化管线：转录结果经 ServiceTextCleanup 润色后再输出（翻译模式跳过）
//   5. 自动发送逻辑：off（不发送）/ always（立即发送）/ smart（倒计时后发送，期间可取消或追加录音）
//   6. 音频验证：最小数据量 + RMS 音量阈值（受 enableSilenceDetection 开关控制）
//   7. 网络回退：Cloud API 失败时自动切换到本地 WhisperKit，网络恢复后切回
//
// 状态机：
//   idle ──→ recording ──→ processing ──→ idle
//     ↑           │              │          ↑
//     │           └──→ error ←──┘          │
//     │                  │                  │
//     │                  └── 3s 自动恢复 ──┘
//     │
//     └── waitingToSend（智能发送倒计时）──→ idle（超时自动发送 / 用户取消）
//
// API 模式与数据流：
//   本地模式：  AudioRecorder → getAudioSamples (Float32) → ServiceLocalWhisper.transcribe → outputText
//   网络模式：  AudioRecorder → stopAndValidateRecording (M4A) → ServiceCloudOpenAI.transcribe → outputText
//   实时模式：  AudioRecorder → onAudioChunk (PCM16) → ServiceRealtimeOpenAI (WebSocket) → outputText
//   翻译模式：  AudioRecorder → stopAndValidateRecording (M4A) → ServiceCloudOpenAI.translate/translateTwoStep → outputText
//   网络回退：  Cloud API 失败 → shouldFallbackToLocal → fallbackToLocalTranscription → 进入 fallback 模式
//
// 依赖：
//   - AudioRecorder：音频采集（标准/流式两种模式）
//   - ServiceCloudOpenAI：HTTP API 转写和翻译
//   - ServiceRealtimeOpenAI：WebSocket 流式转写
//   - ServiceLocalWhisper：WhisperKit 本地转写
//   - ServiceTextCleanup：GPT-4o-mini 文本优化
//   - TextInputter：文字输入到活动窗口
//   - Config：运行时配置
//   - EngineeringOptions：工程级开关与技术常量（超时、阈值等）
//
// 架构角色：
//   由 AppDelegate 创建，通过回调连接到 StatusBarController（UI 更新）和 HotkeyManager（用户输入）。
//   设置变更通过 AppDelegate 的 Combine 订阅实时传入。

import Cocoa

/// 录音控制器
/// 负责管理录音状态、协调各种 API 模式的录音流程
class RecordingController {

    // MARK: - 类型定义

    /// 应用状态
    enum AppState {
        case idle           // 待机
        case recording      // 录音中
        case processing     // 处理中
        case waitingToSend  // 智能模式：等待发送倒计时
        case error          // 错误
    }

    /// 录音模式
    enum RecordingMode {
        case transcribe     // 语音转文字
        case translate      // 语音翻译（翻译成英文）
    }

    // MARK: - 回调

    /// 状态变化回调
    var onStateChange: ((AppState) -> Void)?

    /// 错误回调
    var onError: ((String) -> Void)?

    /// 转写完成回调（传递转写结果文本）
    var onTranscriptionResult: ((String) -> Void)?

    // MARK: - 依赖组件

    private let audioRecorder: AudioRecorder
    private var whisperService: ServiceCloudOpenAI
    private var realtimeService: ServiceRealtimeOpenAI
    private let localWhisperService: ServiceLocalWhisper
    private let textInputter: TextInputter
    private var textCleanupService: ServiceTextCleanup
    private let config: Config

    // MARK: - 状态

    private(set) var currentState: AppState = .idle {
        didSet {
            onStateChange?(currentState)
        }
    }

    /// 当前录音模式
    private var currentMode: RecordingMode = .transcribe

    /// 用户选择的 API 模式（首选模式）
    var preferredApiMode: StatusBarController.ApiMode = .cloud

    /// 当前实际使用的 API 模式（可能因网络回退而与 preferredApiMode 不同）
    var currentApiMode: StatusBarController.ApiMode = .cloud

    /// 是否处于网络回退状态（Cloud → Local）
    private(set) var isInFallbackMode: Bool = false

    /// 当前自动发送模式
    var autoSendMode: StatusBarController.AutoSendMode = .smart

    /// 智能模式等待时间（秒）
    var smartModeWaitDuration: TimeInterval = UserSettings.smartModeWaitDuration

    /// 当前文本优化模式
    var textCleanupMode: TextCleanupMode = .off

    /// 是否播放提示音
    var playSound: Bool = true

    /// 上次录音时长（秒），用于动态超时计算
    private var lastRecordingDuration: TimeInterval = 0

    /// 智能模式的等待发送定时器
    private var pendingSendTimer: DispatchWorkItem?

    // MARK: - 初始化

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

    /// 动态更新服务实例（API Key 变更时调用）
    func updateServices(
        whisperService: ServiceCloudOpenAI,
        realtimeService: ServiceRealtimeOpenAI,
        textCleanupService: ServiceTextCleanup
    ) {
        guard currentState == .idle || currentState == .error else {
            Log.w("RecordingController: 当前状态 \(currentState) 不允许更新服务")
            return
        }
        self.whisperService = whisperService
        self.realtimeService = realtimeService
        self.textCleanupService = textCleanupService
        setupCallbacks()
    }

    // MARK: - 设置

    private func setupCallbacks() {
        // 音频录制器回调
        audioRecorder.onMaxDurationReached = { [weak self] in
            self?.stopRecording()
        }

        // Realtime 服务回调
        // Delta 模式：实时逐词输出（文本优化开启时抑制 delta 输出）
        realtimeService.onTranscriptionDelta = { [weak self] (delta: String) in
            guard let self = self else { return }
            guard EngineeringOptions.realtimeDeltaMode else { return }
            if self.textCleanupMode == .off {
                self.textInputter.inputTextRaw(delta)
            }
            // 文本优化开启时不输出 delta，等 onTranscriptionComplete 统一处理
        }
        realtimeService.onTranscriptionComplete = { [weak self] (text: String) in
            guard let self = self else { return }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                Log.i("Realtime: 一段转录完成 - \(trimmedText)")
                if self.textCleanupMode != .off {
                    // 文本优化开启时，用 outputText 清理并输出完整文本
                    self.outputText(trimmedText, action: "实时语音识别")
                } else {
                    self.onTranscriptionResult?(trimmedText)
                }
            }
        }
        realtimeService.onError = { [weak self] (error: Error) in
            self?.handleError("实时转录错误: \(error.localizedDescription)")
        }
    }

    // MARK: - 公共方法

    /// 开始录音（由 Push-to-Talk 等外部触发调用）
    func beginRecording(mode: RecordingMode) {
        guard currentState == .idle || currentState == .error || currentState == .waitingToSend else {
            Log.i("无法开始录音，当前状态: \(currentState)")
            return
        }
        // 非本地模式需要 API Key
        if currentApiMode != .local && (KeychainHelper.load() ?? "").isEmpty {
            onError?("请先在设置中配置 OpenAI API Key")
            return
        }
        if currentState == .error {
            currentState = .idle
        }
        currentMode = mode
        startRecording()
    }

    /// 切换录音状态
    func toggleRecording(mode: RecordingMode) {
        switch currentState {
        case .idle:
            currentMode = mode
            startRecording()
        case .recording:
            stopRecording()
        case .processing:
            Log.i("正在处理中，请稍候...")
        case .waitingToSend:
            // 智能模式中按下热键：取消发送倒计时，回到待机状态
            cancelSmartMode()
        case .error:
            currentState = .idle
        }
    }

    /// 取消当前录音或处理（由 ESC 键触发）
    func cancelRecording() {
        switch currentState {
        case .recording:
            Log.i("用户取消录音")
            // 停止录音，丢弃数据
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
            Log.i("用户取消处理")
            // 无法真正取消 API 调用，但回到 idle 忽略后续结果
            currentState = .idle

        case .waitingToSend:
            cancelSmartMode()

        case .idle, .error:
            break
        }
    }

    // MARK: - 录音控制

    /// 开始录音
    private func startRecording() {
        // 非本地模式需要 API Key（翻译模式也需要，因为翻译始终使用网络 API）
        let needsApiKey = currentApiMode != .local || currentMode == .translate
        if needsApiKey && (KeychainHelper.load() ?? "").isEmpty {
            onError?("请先在设置中配置 OpenAI API Key")
            return
        }

        // 如果在智能模式等待发送中，取消倒计时
        cancelSmartModeForNewRecording()

        let modeText = currentMode == .transcribe ? "语音转文字" : "语音翻译"
        let apiModeText: String
        switch currentApiMode {
        case .local:
            apiModeText = "本地"
        case .cloud:
            apiModeText = "网络"
        case .realtime:
            apiModeText = "实时"
        }
        Log.i("开始录音（\(modeText)模式，\(apiModeText) API）...")

        // 检测麦克风冲突
        if !audioRecorder.checkMicrophoneAvailability() {
            Log.i("麦克风被占用")
            handleError("麦克风正被其他应用使用，请先关闭其他语音输入程序")
            return
        }

        // 实时模式和本地模式只支持转录功能
        // 翻译模式使用 ServiceCloudOpenAI HTTP API，因为实时和本地模式不支持翻译
        if currentApiMode == .local && currentMode == .transcribe {
            startLocalRecording()
        } else if currentApiMode == .realtime && currentMode == .transcribe {
            startRealtimeRecording()
        } else {
            // 网络转录模式和翻译模式都使用非流式录音
            startNonStreamingRecording()
        }
    }

    /// 非流式录音的通用启动方法（用于本地、网络、翻译模式）
    /// 设置状态为录音中，播放提示音，启动非流式录音
    private func startNonStreamingRecording() {
        currentState = .recording
        playStartSound()

        do {
            try audioRecorder.startRecording(
                maxDuration: config.maxRecordingDuration,
                streamingMode: false
            )
        } catch {
            Log.e("录音启动失败: \(error)")
            handleError("录音启动失败: \(error.localizedDescription)")
        }
    }

    /// 使用本地 WhisperKit 开始录音（需先检查模型状态）
    private func startLocalRecording() {
        if !localWhisperService.isReady() {
            let message = localWhisperService.isModelLoading
                ? "WhisperKit 模型正在加载中，请稍候..."
                : "WhisperKit 模型尚未加载，请稍候再试"
            Log.i(message)
            onError?(message)
            // 不设置 error 状态，保持 idle（避免显示黄色三角形误导用户）
            return
        }

        startNonStreamingRecording()
    }

    /// 使用实时 API 开始录音
    private func startRealtimeRecording() {
        Log.i("Realtime: 开始启动实时录音流程")
        // 确保旧连接已清理
        realtimeService.disconnect()
        audioRecorder.onAudioChunk = { [weak self] data in
            self?.realtimeService.sendAudioChunk(data)
        }

        realtimeService.resetTranscription()
        realtimeService.onConnectionStateChange = { [weak self] (state: RealtimeConnectionState) in
            guard let self = self else { return }
            Log.i("Realtime: 连接状态变化 → \(state)")

            switch state {
            case .configured:
                DispatchQueue.main.async {
                    Log.i("Realtime: 会话已配置，开始录音")
                    self.currentState = .recording
                    self.playStartSound()

                    do {
                        try self.audioRecorder.startRecording(
                            maxDuration: self.config.maxRecordingDuration,
                            streamingMode: true,
                            sampleRate: EngineeringOptions.realtimeSampleRate
                        )
                        Log.i("Realtime: 录音已启动 (24kHz)")
                    } catch {
                        Log.e("Realtime: 录音启动失败: \(error)")
                        self.handleError("录音启动失败: \(error.localizedDescription)")
                        self.realtimeService.disconnect()
                    }
                }

            case .disconnected:
                DispatchQueue.main.async {
                    Log.w("Realtime: 连接断开，当前状态: \(self.currentState)")
                    if self.currentState == .recording {
                        self.handleError("WebSocket 连接断开")
                    }
                }

            default:
                Log.d("Realtime: 连接状态: \(state)")
                break
            }
        }

        Log.i("Realtime: 调用 connect()...")
        realtimeService.connect()
    }

    /// 停止录音并处理
    func stopRecording() {
        guard currentState == .recording else { return }

        Log.i("停止录音...")
        playStopSound()

        if currentApiMode == .local && currentMode == .transcribe {
            stopLocalRecording()
        } else if currentApiMode == .cloud && currentMode == .transcribe {
            stopCloudRecording()
        } else if currentApiMode == .realtime && currentMode == .transcribe {
            stopRealtimeRecording()
        } else {
            // 翻译模式
            stopTranslationRecording()
        }
    }

    /// 停止录音并验证音频有效性（用于网络转录和翻译模式）
    /// 返回有效的录音结果，如果音频无效（太短、音量过低等）则返回 nil 并重置状态
    private func stopAndValidateRecording() -> AudioRecorder.RecordingResult? {
        let averageRMS = audioRecorder.getLastRecordingAverageRMS()

        guard let recording = audioRecorder.stopRecording() else {
            Log.i("没有录到音频数据")
            currentState = .idle
            return nil
        }

        Log.i("录音结束，数据大小: \(recording.data.count) 字节，格式: \(recording.format)，平均音量: \(averageRMS)")

        if EngineeringOptions.enableSilenceDetection {
            if recording.data.count < EngineeringOptions.minAudioDataSize {
                Log.i("音频太短，忽略")
                currentState = .idle
                return nil
            }

            if averageRMS < EngineeringOptions.minVoiceThreshold {
                Log.i("音频音量太低 (\(averageRMS) < \(EngineeringOptions.minVoiceThreshold))，可能只有噪音，跳过识别")
                currentState = .idle
                return nil
            }
        }

        return recording
    }

    /// 停止网络 API 模式录音并转录
    /// 如果网络 API 失败（超时/网络错误），自动回退到本地 WhisperKit
    private func stopCloudRecording() {
        // 在 stopRecording() 清空缓冲区之前，先保存原始采样数据用于可能的本地回退
        let savedSamples = audioRecorder.getAudioSamples()
        let audioDuration = audioRecorder.getCurrentRecordingDuration()
        lastRecordingDuration = audioDuration

        guard let recording = stopAndValidateRecording() else { return }

        currentState = .processing
        Log.i("正在调用 Whisper API（网络转录）...")
        whisperService.transcribe(audioData: recording.data, format: recording.format, audioDuration: audioDuration) { [weak self] result in
            switch result {
            case .success:
                self?.handleResult(result, action: "网络语音识别")
            case .failure(let error):
                // 网络错误时尝试本地回退
                if self?.shouldFallbackToLocal(error: error) == true {
                    Log.w("网络 API 失败，尝试回退到本地 WhisperKit: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self?.fallbackToLocalTranscription(samples: savedSamples)
                    }
                } else {
                    self?.handleResult(result, action: "网络语音识别")
                }
            }
        }
    }

    /// 判断是否应该回退到本地转录
    private func shouldFallbackToLocal(error: Error) -> Bool {
        // 如果网络回退功能被禁用，直接返回 false
        guard EngineeringOptions.enableCloudFallback else { return false }

        // 只有本地 WhisperKit 已加载才能回退
        guard localWhisperService.isReady() else { return false }

        if let whisperError = error as? ServiceCloudOpenAI.WhisperError {
            switch whisperError {
            case .networkError:
                return true  // 网络超时、连接失败等
            default:
                return false  // API 错误（如认证失败）不回退
            }
        }
        return false
    }

    /// 使用本地 WhisperKit 进行回退转录
    private func fallbackToLocalTranscription(samples: [Float]) {
        guard !samples.isEmpty else {
            Log.w("回退失败：没有保存的音频采样数据")
            handleError("网络 API 失败，且无法回退到本地转录")
            return
        }

        Log.i("回退到本地 WhisperKit 转录，采样点数: \(samples.count)")

        // 进入回退模式：后续转录都使用本地，直到网络恢复
        if !isInFallbackMode {
            isInFallbackMode = true
            currentApiMode = .local
            Log.i("已进入网络回退模式，后续转录将使用本地 WhisperKit")
        }

        onError?("网络 API 超时，已自动切换到本地识别")
        localTranscribeWithTimeout(samples: samples, action: "本地回退语音识别")
    }

    /// 停止翻译模式录音并翻译
    private func stopTranslationRecording() {
        let audioDuration = audioRecorder.getCurrentRecordingDuration()
        lastRecordingDuration = audioDuration
        guard let recording = stopAndValidateRecording() else { return }

        currentState = .processing
        translateAudio(recording, audioDuration: audioDuration)
    }

    /// 停止本地模式录音并转录
    private func stopLocalRecording() {
        // 在停止录音前获取原始采样数据
        let samples = audioRecorder.getAudioSamples()
        let averageRMS = audioRecorder.getLastRecordingAverageRMS()
        lastRecordingDuration = audioRecorder.getCurrentRecordingDuration()

        // 停止录音（忽略返回的 M4A 编码数据，本地模式直接使用原始采样）
        _ = audioRecorder.stopRecording()

        Log.i("本地模式录音结束，采样点数: \(samples.count)，平均音量: \(averageRMS)")

        // 音量/数据检查（同标准模式）
        if EngineeringOptions.enableSilenceDetection {
            if samples.count < Int(EngineeringOptions.sampleRate * EngineeringOptions.minAudioDuration) {
                Log.i("音频太短，忽略")
                currentState = .idle
                return
            }

            if averageRMS < EngineeringOptions.minVoiceThreshold {
                Log.i("音频音量太低 (\(averageRMS) < \(EngineeringOptions.minVoiceThreshold))，可能只有噪音，跳过识别")
                currentState = .idle
                return
            }
        }

        currentState = .processing
        localTranscribeWithTimeout(samples: samples, action: "本地语音识别")
    }

    /// 带超时的本地 WhisperKit 转录
    /// 使用 TaskGroup 竞速：转录任务和超时定时器同时运行，先完成的决定结果
    private func localTranscribeWithTimeout(samples: [Float], action: String) {
        let audioDuration = Double(samples.count) / EngineeringOptions.sampleRate
        let minutes = audioDuration / 60.0
        let timeout = min(max(minutes * 10, EngineeringOptions.apiProcessingTimeoutMin), EngineeringOptions.apiProcessingTimeoutMax)
        Log.i("\(action): 音频时长 \(String(format: "%.1f", audioDuration))s，本地处理超时 \(String(format: "%.0f", timeout))s")

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
                        Log.i("\(action)结果为空")
                        self.currentState = .idle
                    } else {
                        self.outputText(trimmedText, action: action)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    Log.e("\(action)超时（\(String(format: "%.0f", timeout))秒）")
                    self.handleError("\(action)超时，请尝试缩短录音时长")
                }
            } catch {
                await MainActor.run {
                    Log.e("\(action)失败: \(error)")
                    self.handleError("\(action)失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 停止实时模式录音
    private func stopRealtimeRecording() {
        _ = audioRecorder.stopRecording()
        audioRecorder.onAudioChunk = nil
        realtimeService.disconnect()
        currentState = .idle
        handleAutoSend()
    }
    // MARK: - 音频处理

    /// 翻译音频（根据配置选择翻译方法）
    private func translateAudio(_ recording: AudioRecorder.RecordingResult, audioDuration: TimeInterval) {
        if config.translationMethod == "two-step" {
            Log.i("正在调用两步翻译（转录 + GPT 翻译）...")
            whisperService.translateTwoStep(audioData: recording.data, format: recording.format, audioDuration: audioDuration) { [weak self] result in
                self?.handleResult(result, action: "语音翻译(两步)")
            }
        } else {
            Log.i("正在调用 Whisper API（直接翻译）...")
            whisperService.translate(audioData: recording.data, format: recording.format, audioDuration: audioDuration) { [weak self] result in
                self?.handleResult(result, action: "语音翻译")
            }
        }
    }

    /// 处理 API 结果
    private func handleResult(_ result: Result<String, Error>, action: String) {
        DispatchQueue.main.async { [weak self] in
            switch result {
            case .success(let text):
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedText.isEmpty {
                    Log.i("\(action)结果为空")
                    self?.currentState = .idle
                } else {
                    self?.outputText(trimmedText, action: action)
                }

            case .failure(let error):
                Log.i("\(action)失败: \(error)")
                self?.handleError("\(action)失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 错误处理

    /// 处理错误并自动恢复
    ///
    /// 将状态设为 error，通知 StatusBarController 显示错误信息，
    /// 然后在 3 秒后自动恢复为 idle 状态（防止应用卡在错误状态）
    private func handleError(_ message: String) {
        currentState = .error
        onError?(message)

        // 延迟自动恢复，给用户查看错误信息的时间
        DispatchQueue.main.asyncAfter(deadline: .now() + EngineeringOptions.errorRecoveryDelay) { [weak self] in
            if self?.currentState == .error {
                self?.currentState = .idle
            }
        }
    }

    // MARK: - 网络回退与恢复

    /// 用户手动切换 API 模式时调用
    /// 清除回退状态，尊重用户选择
    func userDidChangeApiMode(_ mode: StatusBarController.ApiMode) {
        preferredApiMode = mode
        currentApiMode = mode
        if isInFallbackMode {
            isInFallbackMode = false
            Log.i("用户手动切换 API 模式，退出回退状态")
        }
    }

    /// Cloud API 网络恢复后调用（由 NetworkHealthMonitor 触发）
    func recoverFromFallback() {
        guard isInFallbackMode else { return }
        isInFallbackMode = false
        currentApiMode = preferredApiMode
        Log.i("网络已恢复，切回 \(preferredApiMode.rawValue) 模式")
    }

    // MARK: - 辅助方法

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

    // MARK: - 统一文本输出

    /// 统一的文本输出方法
    /// 如果文本优化开启，先调用 API 清理文本再输出；失败时回退到原始文本
    /// - Parameters:
    ///   - text: 待输出的文本（已 trim）
    ///   - action: 操作描述（用于日志）
    private func outputText(_ text: String, action: String) {
        // 翻译模式不做文本优化（翻译结果已经是处理过的）
        guard textCleanupMode != .off && currentMode != .translate else {
            Log.i("\(action)结果: \(text)")
            onTranscriptionResult?(text)
            textInputter.inputText(text)
            currentState = .idle
            handleAutoSend()
            return
        }

        Log.i("\(action)结果（优化前）: \(text)")
        textCleanupService.cleanup(text: text, mode: textCleanupMode, audioDuration: lastRecordingDuration) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let finalText: String
                switch result {
                case .success(let cleanedText):
                    if cleanedText.isEmpty {
                        Log.w("文本优化返回空结果，使用原始文本")
                        finalText = text
                    } else {
                        finalText = cleanedText
                    }
                case .failure(let error):
                    Log.w("文本优化失败，使用原始文本: \(error.localizedDescription)")
                    finalText = text
                }
                Log.i("\(action)结果（最终）: \(finalText)")
                self.onTranscriptionResult?(finalText)
                self.textInputter.inputText(finalText)
                self.currentState = .idle
                self.handleAutoSend()
            }
        }
    }

    // MARK: - 自动发送

    /// 根据当前自动发送模式处理文本输入后的发送逻辑
    private func handleAutoSend() {
        switch autoSendMode {
        case .off:
            // 仅转写，不做额外操作
            break

        case .always:
            // 延迟后自动按 Enter
            DispatchQueue.main.asyncAfter(deadline: .now() + EngineeringOptions.autoSendDelay) { [weak self] in
                self?.textInputter.pressReturnKey()
                Log.i("自动发送: 已按下 Enter")
            }

        case .smart:
            // 进入等待发送状态
            startSmartModeCountdown()
        }
    }

    /// 开始智能模式倒计时
    private func startSmartModeCountdown() {
        currentState = .waitingToSend
        Log.i("智能模式: 开始 \(smartModeWaitDuration) 秒倒计时...")

        // 创建定时器任务
        let timerWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // 如果状态仍然是等待发送，则执行发送
            if self.currentState == .waitingToSend {
                self.textInputter.pressReturnKey()
                Log.i("智能模式: 倒计时结束，已自动发送")
                self.cleanupSmartMode()
                self.currentState = .idle
            }
        }
        pendingSendTimer = timerWork
        DispatchQueue.main.asyncAfter(deadline: .now() + smartModeWaitDuration, execute: timerWork)
    }

    /// 取消智能模式倒计时（由双击 Option 触发）
    private func cancelSmartMode() {
        cleanupSmartMode()
        currentState = .idle
        Log.i("智能模式: 用户按下热键取消发送，文本保留")
    }

    /// 智能模式中用户按下热键开始新录音（追加模式）
    /// 在 startRecording 中调用
    private func cancelSmartModeForNewRecording() {
        if currentState == .waitingToSend {
            Log.i("智能模式: 用户开始新录音，取消发送倒计时")
            cleanupSmartMode()
        }
    }

    /// 清理智能模式的定时器
    private func cleanupSmartMode() {
        pendingSendTimer?.cancel()
        pendingSendTimer = nil
    }

}
