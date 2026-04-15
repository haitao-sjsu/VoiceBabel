// UserSettings.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 用户偏好默认值注册表 —— 作为 SettingsStore（UserDefaults）的 fallback 默认值。
//
// 职责：
//   为所有用户可配置偏好提供硬编码的初始默认值。当 UserDefaults 中没有对应记录时，
//   SettingsStore 会回退到这里的值。同时也被 Config.load() 引用作为启动时的初始配置。
//
// 与 SettingsStore 的关系：
//   所有设置项已迁移到 SettingsStore（UserDefaults + SwiftUI 设置面板）。
//   本文件仅保留默认值定义，不再作为运行时配置的直接来源。
//
// 与 EngineeringOptions 的区别：
//   - UserSettings：面向用户的偏好（语言、模式、提示音等），可在设置面板中调整
//   - EngineeringOptions：面向开发者的工程选项（API 密钥、管线开关等），不对用户暴露
//
// 依赖：无
//
// 架构角色：
//   被 SettingsStore 和 Config 引用，提供默认值。

import Foundation

struct UserSettings {

    // ============================================================
    // MARK: - 语言配置
    // ============================================================

    /// 语音识别语言
    /// - 空字符串 ""：自动检测语言（适合多语言场景）
    /// - "zh"：中文（指定语言可提高准确率）
    /// - "en"：英文
    /// - "ja"：日文
    /// - "ko"：韩文
    /// - 完整列表：https://platform.openai.com/docs/guides/speech-to-text
    static let whisperLanguage = ""

    // ============================================================
    // MARK: - API 模式配置
    // ============================================================

    /// 默认 API 模式
    /// - "local"：本地识别模式（WhisperKit）
    /// - "cloud"：网络 API 模式（gpt-4o-transcribe）
    /// - "realtime"：实时模式（WebSocket）
    static let defaultApiMode = "cloud"

    // ============================================================
    // MARK: - 优先级配置
    // ============================================================

    /// 转录模式优先级（有序数组，索引 0 = 最高优先级）
    /// Realtime 模式独立，不参与优先级队列
    static let transcriptionPriority = ["cloud", "local"]

    /// 翻译引擎优先级（有序数组，索引 0 = 最高优先级）
    /// - "apple"：Apple Translation（本地离线）
    /// - "cloud"：Cloud GPT（gpt-4o-mini，需网络）
    static let translationEnginePriority = ["apple", "cloud"]

    // ============================================================
    // MARK: - 自动发送配置
    // ============================================================

    /// 自动发送模式
    /// - "off"：仅转写，不自动发送
    /// - "always"：转写后自动按 Enter 发送
    /// - "smart"：智能模式，转写后倒计时，可取消或追加录音
    static let autoSendMode = "always"

    /// 智能模式等待时间（秒）
    static let smartModeWaitDuration: TimeInterval = 3.0

    // ============================================================
    // MARK: - 文本优化配置
    // ============================================================

    /// 文本优化模式
    /// - "off"：关闭
    /// - "neutral"：自然润色
    /// - "formal"：正式风格
    /// - "casual"：口语风格
    static let textCleanupMode = "off"

    // ============================================================
    // MARK: - 界面配置
    // ============================================================

    /// 是否播放提示音
    static let playSound = true
}
