// Config.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 运行时配置结构体 —— 从 SettingsDefaults 和 EngineeringOptions 两个来源组装。
//
// 职责：
//   作为配置抽象层，将 SettingsDefaults（用户偏好默认值）和 EngineeringOptions（工程级选项）
//   统一封装为一个结构体，供 AppDelegate 在启动时创建并传递给各组件初始化。
//
// 注意：
//   - Config 是启动时的一次性快照，不会随用户设置变更而更新
//   - 运行时设置变更通过 SettingsStore 的 Combine $publisher 实时传播
//   - 部分 EngineeringOptions 字段未经过 Config（如 enableSilenceDetection），
//     由组件直接访问 EngineeringOptions
//
// 依赖：
//   - SettingsDefaults：用户偏好默认值
//   - EngineeringOptions：工程级配置选项
//
// 架构角色：
//   由 AppDelegate 调用 Config.load() 创建，传递给 RecordingController 和各 Service 初始化。

import Foundation

struct Config {

    // MARK: - 工程选项（来自 EngineeringOptions）

    let openaiApiKey: String
    let whisperModel: String
    let maxRecordingDuration: TimeInterval
    let inputMethod: String
    let typingDelay: TimeInterval

    // MARK: - 用户设置（来自 SettingsDefaults）

    let whisperLanguage: String
    let defaultApiMode: String
    let autoSendMode: String
    var delayedSendDuration: TimeInterval
    let textCleanupMode: String

    // MARK: - 加载配置

    /// 从 SettingsDefaults 和 EngineeringOptions 加载配置
    static func load() -> Config {
        Log.d("Loading config...")

        let config = Config(
            // 工程选项
            openaiApiKey: KeychainHelper.load() ?? "",
            whisperModel: EngineeringOptions.whisperModel,
            maxRecordingDuration: EngineeringOptions.maxRecordingDuration,
            inputMethod: EngineeringOptions.inputMethod,
            typingDelay: EngineeringOptions.typingDelay,
            // 用户设置
            whisperLanguage: SettingsDefaults.whisperLanguage,
            defaultApiMode: SettingsDefaults.defaultApiMode,
            autoSendMode: SettingsDefaults.autoSendMode,
            delayedSendDuration: SettingsDefaults.delayedSendDuration,
            textCleanupMode: SettingsDefaults.textCleanupMode
        )

        Log.d("Config loaded")
        return config
    }
}
