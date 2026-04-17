// AudioRecorder.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 音频录制模块 —— 使用 AVAudioEngine 采集麦克风音频并进行采样率转换。
//
// 职责：
//   1. 麦克风采集：通过 AVAudioEngine + installTap 实时获取音频数据
//   2. 采样率转换：将系统采样率（48kHz/44.1kHz）降采样至目标采样率（16kHz）
//   3. 内存缓冲：音频数据缓存在内存（audioBuffer），停止时返回原始 [Float] 采样
//   4. 麦克风冲突检测：Core Audio 设备占用检测 + macOS 系统听写冲突检测
//   5. 录音保护：最长录音时间限制，防止意外长时间录音
//
// 音频处理流程：
//   麦克风 → AVAudioEngine.inputNode → installTap → processAudioBuffer()
//     → AVAudioConverter（采样率转换）→ audioBuffer（Float32 内存缓冲）
//       → stopRecording() → [Float] 原始采样（编码由下游处理）
//
// 依赖：
//   - AVFoundation：AVAudioEngine, AVAudioConverter, AVCaptureDevice（权限检查）
//   - CoreAudio：AudioObjectGetPropertyData（麦克风占用检测）
//   - EngineeringOptions：sampleRate, checkTimerInterval
//
// 架构角色：
//   由 AppDelegate 创建，由 AppController 控制其启停。
//   产出的 [Float] 采样传递给 TranscriptionManager 进行编码和转录。

import AVFoundation
import Cocoa
import CoreAudio

class AudioRecorder {

    // MARK: - 回调

    /// 录音达到最长时间限制时触发
    var onMaxDurationReached: (() -> Void)?

    // MARK: - 私有属性

    /// AVAudioEngine 实例，负责管理音频输入节点和信号处理链
    private var audioEngine: AVAudioEngine?

    /// 所有录音采样数据的内存缓冲区（Float32 格式，值域 -1.0 ~ 1.0）
    /// 停止录音时整体返回给调用方
    private var audioBuffer: [Float] = []

    /// 是否正在录音（外部只读）
    private(set) var isRecording = false

    // MARK: - 录音配置
    // 这些属性在每次 startRecording() 时设置
    // 使用可选类型明确表示"尚未开始录音"的状态

    /// 最长录音时间（秒），防止意外长时间录音
    private var maxRecordingDuration: TimeInterval?

    // MARK: - 录音状态

    /// 录音开始时间，用于计算已录音时长
    private var recordingStartTime: Date?

    /// 周期性检查定时器（每 0.5 秒检查一次超时）
    private var checkTimer: Timer?

    // MARK: - 公共方法

    /// 检查麦克风是否可用（未被其他应用占用）
    ///
    /// 通过两种方式检测冲突：
    /// 1. Core Audio 检测默认输入设备是否被任何进程使用（Zoom、FaceTime 等）
    /// 2. 检测 macOS 系统听写是否正在录音（通过其悬浮窗口判断）
    ///
    /// - Returns: true 表示麦克风可用
    func checkMicrophoneAvailability() -> Bool {
        // 方式一：Core Audio 检测默认输入设备是否在被使用
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size, &deviceID
        )

        if status == noErr, deviceID != kAudioObjectUnknown {
            var isRunning: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere

            let runningStatus = AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &size, &isRunning
            )

            if runningStatus == noErr, isRunning != 0 {
                Log.i(LocaleManager.shared.logLocalized("Microphone in use by another program detected (Core Audio)"))
                return false
            }
        }

        // 方式二：检测 macOS 系统听写是否激活
        // DictationIM 进程常驻后台，但只有在听写激活时才会创建悬浮窗口
        if isDictationActive() {
            Log.i(LocaleManager.shared.logLocalized("System dictation detected running"))
            return false
        }

        return true
    }

    /// 检查 macOS 系统听写是否正在激活状态
    /// 通过检测 DictationIM 是否有可见窗口来判断（听写激活时会显示悬浮麦克风面板）
    private func isDictationActive() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in windowList {
            if let owner = window[kCGWindowOwnerName as String] as? String,
               owner == "DictationIM" {
                return true
            }
        }
        return false
    }

    /// 开始录音
    ///
    /// 根据传入的参数配置录音行为，创建 AVAudioEngine 并开始采集。
    /// 麦克风音频会通过 installTap 回调实时获取，经采样率转换后存入缓冲区。
    ///
    /// - Parameters:
    ///   - maxDuration: 最长录音时间（秒）
    /// - Throws: RecordingError
    func startRecording(
        maxDuration: TimeInterval
    ) throws {
        guard !isRecording else {
            Log.i(LocaleManager.shared.logLocalized("Already recording"))
            return
        }

        // 保存本次录音的配置参数
        self.maxRecordingDuration = maxDuration

        let sampleRate = EngineeringOptions.sampleRate

        // 检查并请求麦克风权限
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break  // 已授权，继续
        case .notDetermined:
            // 首次请求权限（异步弹出系统授权对话框）
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    Log.w(LocaleManager.shared.logLocalized("User denied microphone permission"))
                }
            }
            // 首次请求时立即抛出错误，等待用户授权后重试
            throw RecordingError.permissionDenied
        case .denied, .restricted:
            Log.w(LocaleManager.shared.logLocalized("Microphone permission denied or restricted"))
            throw RecordingError.permissionDenied
        @unknown default:
            break
        }

        // 重置所有状态
        audioBuffer.removeAll()
        recordingStartTime = Date()

        // 创建 AVAudioEngine（每次录音新建一个实例，避免残留状态）
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw RecordingError.engineCreationFailed
        }

        // 获取麦克风输入节点及其原始格式（通常为 48kHz/44.1kHz，取决于硬件）
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // 创建目标格式：16kHz 单声道 Float32（Whisper 要求）
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.formatCreationFailed
        }

        // 在输入节点上安装音频采集回调（Tap）
        // 每当麦克风产生新的音频数据时，都会调用此闭包
        // bufferSize 1024 表示每次请求约 1024 帧的数据
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, from: inputFormat, to: targetFormat)
        }

        // 启动音频引擎，开始采集
        try audioEngine.start()
        isRecording = true

        // 启动周期性检查定时器（检查静默和超时）
        startCheckTimer()

        // 打印启动信息（方便调试）
        let lm = LocaleManager.shared
        var modeInfo = lm.logLocalized("manual stop mode")
        if maxDuration > 0 {
            modeInfo += ", max \(Int(maxDuration / 60)) min"
        }
        Log.i(lm.logLocalized("Recording started") + " (\(modeInfo))")
    }

    /// 停止录音并返回原始 Float32 采样数据
    ///
    /// 停止 AVAudioEngine，返回缓冲区中的全部采样数据。
    /// 编码（M4A/WAV）由下游调用方负责。
    ///
    /// - Returns: 原始 Float32 采样数据，无数据时返回 nil
    func stopRecording() -> [Float]? {
        guard isRecording else {
            Log.w(LocaleManager.shared.logLocalized("AudioRecorder: stopRecording called but not recording"))
            return nil
        }

        // 停止定时器
        checkTimer?.invalidate()
        checkTimer = nil

        // 停止音频引擎并释放资源
        audioEngine?.inputNode.removeTap(onBus: 0)   // 移除采集回调
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let lm = LocaleManager.shared
        Log.i(lm.logLocalized("Recording stopped, duration:") + " \(String(format: "%.1f", duration))s, " + lm.logLocalized("sample count:") + " \(audioBuffer.count)")

        guard !audioBuffer.isEmpty else { return nil }

        let samples = audioBuffer
        audioBuffer.removeAll()
        return samples
    }

    /// 计算采样数据的平均音量（RMS 均方根值）
    ///
    /// 用于判断录音是否包含有效语音。如果平均音量低于阈值，
    /// 说明录音期间用户可能没有说话，可以跳过 API 调用以节省费用。
    ///
    /// - Parameters:
    ///   - samples: Float32 采样数据
    /// - Returns: 平均 RMS 值（0.0 ~ 1.0）
    static func averageRMS(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(0) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    /// 获取当前已录音的时长（秒）
    func getCurrentRecordingDuration() -> TimeInterval {
        guard let startTime = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }

    // MARK: - 私有方法

    /// 处理从麦克风采集到的音频数据
    ///
    /// 此方法在音频采集线程（非主线程）上被调用。
    /// 主要完成：采样率转换 → 存储到缓冲区 → 流式发送 → 静默检测
    ///
    /// - Parameters:
    ///   - buffer: 麦克风原始音频数据（系统采样率）
    ///   - inputFormat: 麦克风原始格式（如 48kHz/44.1kHz）
    ///   - targetFormat: 目标格式（16kHz 单声道 Float32）
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, from inputFormat: AVAudioFormat, to targetFormat: AVAudioFormat) {
        // 创建采样率转换器（输入格式 → 目标格式）
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Log.e("AudioRecorder: AVAudioConverter creation failed")
            return
        }

        // 根据采样率比例计算输出帧数
        // 例如：48kHz → 16kHz，比例为 1/3，输出帧数为输入的 1/3
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        // 创建输出缓冲区
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            Log.e("AudioRecorder: output buffer allocation failed")
            return
        }

        // 执行采样率转换
        // inputBlock 提供输入数据：每次请求时返回原始 buffer
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            Log.e(LocaleManager.shared.logLocalized("Audio conversion error:") + " \(error)")
            return
        }

        // 从输出缓冲区提取 Float32 采样数据
        guard let floatData = outputBuffer.floatChannelData?[0] else {
            Log.e("AudioRecorder: float channel data extraction failed")
            return
        }

        let samples = Array(UnsafeBufferPointer(start: floatData, count: Int(outputBuffer.frameLength)))

        // 将转换后的采样数据追加到总缓冲区
        audioBuffer.append(contentsOf: samples)
    }

    /// 启动周期性检查定时器
    ///
    /// 每 0.5 秒（EngineeringOptions.checkTimerInterval）检查一次：
    /// 是否达到最长录音时间 → 触发 onMaxDurationReached
    private func startCheckTimer() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: EngineeringOptions.checkTimerInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // 检查是否超过最长录音时间
            let currentDuration = self.getCurrentRecordingDuration()
            if let maxDuration = self.maxRecordingDuration, currentDuration >= maxDuration {
                Log.i(LocaleManager.shared.logLocalized("Max recording duration reached") + " \(Int(maxDuration / 60)) min, " + LocaleManager.shared.logLocalized("auto stopping recording"))
                DispatchQueue.main.async {
                    self.onMaxDurationReached?()
                }
                return
            }
        }
    }

    // MARK: - 类型定义

    /// 录音错误类型
    enum RecordingError: Error, LocalizedError {
        case permissionDenied       // 麦克风权限被拒绝
        case engineCreationFailed   // AVAudioEngine 创建失败
        case formatCreationFailed   // 音频格式创建失败
        case microphoneInUse        // 麦克风被其他应用占用

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return String(localized: "Microphone permission denied, please authorize in System Settings")
            case .engineCreationFailed:
                return String(localized: "Audio engine creation failed")
            case .formatCreationFailed:
                return String(localized: "Audio format creation failed")
            case .microphoneInUse:
                return String(localized: "Microphone is in use by another app")
            }
        }
    }
}
