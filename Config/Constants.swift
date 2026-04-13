// Constants.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 编译期常量命名空间 —— 集中管理应用中所有技术层面的固定参数。
//
// 职责：
//   提供全局共用的技术常量，包括音频参数（采样率、阈值）、网络超时、
//   API 端点 URL、音频编码参数、手势检测参数、自动发送参数等。
//   这些值在编译期确定，运行时不可变。
//
// 设计：
//   使用 caseless enum 作为纯命名空间，所有字段均为 static let。
//
// 与 EngineeringOptions 的区别：
//   - Constants：底层技术参数（采样率、超时、URL），通常不需要按场景调整
//   - EngineeringOptions：功能级开关和配置（启用/禁用某功能），开发者按需调整
//
// 依赖：无
//
// 架构角色：
//   被几乎所有组件引用，提供统一的常量定义。

import Foundation

/// 开发者配置常量
/// 这些参数控制应用程序的底层行为，修改需谨慎
enum Constants {

    // MARK: - 音频参数

    /// 音频采样率（Hz）— 用于本地模式和网络 API 模式
    /// - 16000 Hz 是 Whisper / WhisperKit 要求的采样率
    static let sampleRate: Double = 16000

    /// Realtime API 音频采样率（Hz）
    /// - 24000 Hz 是 Realtime API 唯一支持的 PCM 采样率
    static let realtimeSampleRate: Double = 24000

    /// 有效语音的最低音量阈值（RMS 均方根值）
    /// - 用于过滤纯噪音，避免发送无效音频到 API
    /// - 范围：0.0 ~ 1.0，值越小越敏感
    /// - 0.003：适合安静环境
    /// - 0.005：适合有轻微背景噪音的环境
    /// - 0.01：适合嘈杂环境
    static let minVoiceThreshold: Float = 0.001

    // MARK: - 网络参数

    /// API 处理超时下限（秒）
    /// - 短音频的最低等待时间
    static let apiProcessingTimeoutMin: TimeInterval = 5

    /// API 处理超时上限（秒）
    /// - 长音频的最长等待时间（Cloud API、本地 WhisperKit、文本优化共用）
    static let apiProcessingTimeoutMax: TimeInterval = 90

    /// Realtime API 最终结果等待超时（秒）
    /// - 在提交音频后等待最终转录结果的最长时间
    /// - 超时后会断开 WebSocket 连接
    static let realtimeResultTimeout: TimeInterval = 10

    // MARK: - API 端点

    /// Whisper 转录 API 端点
    static let whisperTranscribeURL = "https://api.openai.com/v1/audio/transcriptions"

    /// Whisper 翻译 API 端点
    static let whisperTranslateURL = "https://api.openai.com/v1/audio/translations"

    /// Chat Completions API 端点（用于两步翻译法的第二步）
    static let chatCompletionsURL = "https://api.openai.com/v1/chat/completions"

    /// Realtime API WebSocket 端点（转录专用模式）
    /// - 使用 intent=transcription，仅做语音转文字，不产生对话回复
    /// - 支持模型：gpt-4o-transcribe, gpt-4o-mini-transcribe, whisper-1
    static let realtimeWebSocketURL = "wss://api.openai.com/v1/realtime?intent=transcription"

    // MARK: - 输入参数

    /// 剪贴板粘贴后等待时间（秒）
    /// - 等待系统完成粘贴操作
    static let clipboardPasteDelay: TimeInterval = 0.1

    /// 剪贴板内容恢复延迟（秒）
    /// - 粘贴完成后延迟恢复原剪贴板内容
    static let clipboardRestoreDelay: TimeInterval = 0.1

    // MARK: - 音频格式参数

    /// AAC 编码比特率（bps）
    /// - 语音识别推荐范围：24000 ~ 64000
    /// - 32000 (32 kbps)：较低比特率，适合语音，压缩比高
    /// - 24000 (24 kbps)：最低推荐值，再低可能影响识别
    /// - 64000 (64 kbps)：高质量语音
    static let aacBitRate: Int = 24000

    /// AAC 编码每帧采样数
    static let aacFramesPerPacket: UInt32 = 1024

    /// 最短有效音频时长（秒）
    /// - 短于此时长的音频会被忽略
    static let minAudioDuration: TimeInterval = 0.5

    /// 最小音频数据大小（字节）
    /// - 小于此大小的音频数据会被忽略
    static let minAudioDataSize: Int = 1000

    // MARK: - 定时器参数

    /// 超时检查间隔（秒）
    static let checkTimerInterval: TimeInterval = 0.5

    /// 错误状态自动恢复延迟（秒）
    /// - 发生错误后，自动恢复到待机状态的延迟时间
    static let errorRecoveryDelay: TimeInterval = 3.0

    // MARK: - 网络回退探测参数

    /// Cloud API 回退后的健康探测间隔（秒）
    /// - 回退到本地后，每隔此时间探测一次 Cloud API 是否恢复
    /// - 值越小恢复越快，但会增加网络请求频率
    static let cloudProbeInterval: TimeInterval = 30

    // MARK: - 自动发送参数

    /// 自动发送前的延迟（秒）
    /// - 粘贴完成后等待此时间再按 Enter
    static let autoSendDelay: TimeInterval = 0.15

    // MARK: - Option 键手势参数

    /// Push-to-Talk 按住阈值（秒）
    /// - Option 键按住超过此时间，进入 Push-to-Talk 模式
    /// - 正常双击每次按键约 50-100ms，400ms 足够区分按住和双击
    static let optionHoldThreshold: TimeInterval = 0.3

    /// 双击检测窗口（秒）
    /// - 第一次松开 Option 后，在此时间内再次按下视为双击
    static let doubleTapWindow: TimeInterval = 0.5
}
