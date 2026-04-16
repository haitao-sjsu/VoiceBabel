// EngineeringOptions.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 工程级配置与技术常量 —— 控制音频处理管线各阶段的开关、参数和固定常量。
//
// 职责：
//   集中管理所有面向开发者的工程级配置和底层技术常量，包括：
//   端点 URL、音频参数（采样率、阈值）、音频编码参数（AAC 比特率）、
//   模型选择、网络超时与回退策略、预处理/后处理开关、翻译方法、
//   文本输入方式、手势检测参数、自动发送参数等。
//   这些选项不在 UI 中暴露，由开发者在代码中直接调整。
//   所有字段在编译期确定，运行时不可变。
//
// 设计：
//   使用 caseless enum（无实例化枚举）作为纯命名空间，防止意外实例化。
//   所有字段均为 static let，编译期确定。
//
// 与其他配置文件的关系：
//   - SettingsDefaults：用户偏好默认值（由 SettingsStore 管理）
//   - KeychainHelper：从 Keychain 加载 API Key
//
// 依赖：无
//
// 架构角色：
//   被几乎所有组件引用，提供统一的工程配置和常量定义。
//   部分字段通过 Config.load() 传递给组件，部分由组件直接访问（如 RecordingController
//   直接读取 enableSilenceDetection、AudioRecorder 直接读取 enableAudioCompression）。

import Foundation

enum EngineeringOptions {

    // ============================================================
    // MARK: - OpenAI API
    // ============================================================
    // Cloud 功能通过两个 OpenAI 端点实现：
    //   1. /v1/audio/transcriptions — 语音转文字（Whisper 系列模型）
    //   2. /v1/chat/completions — 文本翻译（GPT 系列模型）
    // 每个端点需要配对一个模型名，在请求体中作为 "model" 参数发送。

    /// 语音转录端点 URL
    static let whisperTranscribeURL = "https://api.openai.com/v1/audio/transcriptions"
    /// 语音转录模型（与 whisperTranscribeURL 配对使用）
    static let whisperModel = "gpt-4o-transcribe"

    /// Chat Completions 端点 URL（用于文本翻译）
    static let chatCompletionsURL = "https://api.openai.com/v1/chat/completions"
    /// 翻译模型（与 chatCompletionsURL 配对使用）
    static let chatTranslationModel = "gpt-4o-mini"

    // ============================================================
    // MARK: - Local models
    // ============================================================

    /// 本地 WhisperKit 模型标识
    static let localWhisperModel = "openai_whisper-large-v3-v20240930_626MB"

    // ============================================================
    // MARK: - Audio capture
    // ============================================================

    /// 音频采样率（Hz）— 用于本地模式和网络 API 模式
    /// - 16000 Hz 是 Whisper / WhisperKit 要求的采样率
    static let sampleRate: Double = 16000

    /// 是否启用静音检测（RMS / 数据大小检查）
    /// 关闭后跳过音量和数据大小检查，所有录音都会提交到转录服务
    static let enableSilenceDetection = true

    /// 有效语音的最低音量阈值（RMS 均方根值）
    /// - 用于过滤纯噪音，避免发送无效音频到 API
    /// - 范围：0.0 ~ 1.0，值越小越敏感
    /// - 0.003：适合安静环境
    /// - 0.005：适合有轻微背景噪音的环境
    /// - 0.01：适合嘈杂环境
    static let minVoiceThreshold: Float = 0.001

    /// 最短有效音频时长（秒）
    /// - 短于此时长的音频会被忽略
    static let minAudioDuration: TimeInterval = 0.5

    /// 最小音频数据大小（字节）
    /// - 小于此大小的音频数据会被忽略
    static let minAudioDataSize: Int = 1000

    /// 最长录音时间（秒）
    static let maxRecordingDuration: TimeInterval = 600

    // ============================================================
    // MARK: - Audio encoding
    // ============================================================

    /// 是否启用音频压缩（M4A/AAC）
    /// 关闭后始终使用 WAV 无压缩格式上传
    static let enableAudioCompression = true

    /// AAC 编码比特率（bps）
    /// - 语音识别推荐范围：24000 ~ 64000
    /// - 32000 (32 kbps)：较低比特率，适合语音，压缩比高
    /// - 24000 (24 kbps)：最低推荐值，再低可能影响识别
    /// - 64000 (64 kbps)：高质量语音
    static let aacBitRate: Int = 24000

    // ============================================================
    // MARK: - Network
    // ============================================================

    /// API 处理超时下限（秒）
    /// - 短音频的最低等待时间
    static let apiProcessingTimeoutMin: TimeInterval = 5

    /// API 处理超时上限（秒）
    /// - 长音频的最长等待时间（Cloud API、本地 WhisperKit、文本优化共用）
    static let apiProcessingTimeoutMax: TimeInterval = 90

    /// 是否启用模式间自动回退（转录和翻译）
    /// 关闭后失败时直接报错，不尝试优先级队列中的下一个模式
    static let enableModeFallback = true

    /// Cloud API 回退后的健康探测间隔（秒）
    /// - 回退到本地后，每隔此时间探测一次 Cloud API 是否恢复
    /// - 值越小恢复越快，但会增加网络请求频率
    static let cloudProbeInterval: TimeInterval = 30

    // ============================================================
    // MARK: - Post-processing
    // ============================================================

    /// 是否启用特殊标签过滤（如 [MUSIC]、[BLANK_AUDIO]）
    static let enableTagFiltering = true

    // ============================================================
    // MARK: - Text output
    // ============================================================

    /// 文本输入方式
    /// - "clipboard": 通过剪贴板粘贴
    /// - "keyboard": 模拟键盘输入
    static let inputMethod = "clipboard"

    /// 键盘输入延迟（秒），仅在 inputMethod = "keyboard" 时生效
    static let typingDelay: TimeInterval = 0

    /// 剪贴板粘贴后等待时间（秒）
    /// - 等待系统完成粘贴操作
    static let clipboardPasteDelay: TimeInterval = 0.1

    /// 剪贴板内容恢复延迟（秒）
    /// - 粘贴完成后延迟恢复原剪贴板内容
    static let clipboardRestoreDelay: TimeInterval = 0.1

    /// 自动发送前的延迟（秒）
    /// - 粘贴完成后等待此时间再按 Enter
    static let autoSendDelay: TimeInterval = 0.15

    // ============================================================
    // MARK: - Hotkey
    // ============================================================

    /// Push-to-Talk 按住阈值（秒）
    /// - Option 键按住超过此时间，进入 Push-to-Talk 模式
    /// - 正常双击每次按键约 50-100ms，400ms 足够区分按住和双击
    static let optionHoldThreshold: TimeInterval = 0.3

    /// 双击检测窗口（秒）
    /// - 第一次松开 Option 后，在此时间内再次按下视为双击
    static let doubleTapWindow: TimeInterval = 0.5

    // ============================================================
    // MARK: - Logging
    // ============================================================

    /// Log message language: "en" or "zh-Hans"
    static let logLanguage = "zh-Hans"

    // ============================================================
    // MARK: - Internal timing
    // ============================================================

    /// 超时检查间隔（秒）
    static let checkTimerInterval: TimeInterval = 0.5

    /// 错误状态自动恢复延迟（秒）
    /// - 发生错误后，自动恢复到待机状态的延迟时间
    static let errorRecoveryDelay: TimeInterval = 3.0
}
