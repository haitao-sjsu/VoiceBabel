// Config.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// API Key 启动快照 —— 从 Keychain 读取 API Key 供各组件初始化。
//
// 职责：
//   启动时从 Keychain 读取 API Key，封装为结构体传递给需要网络访问的组件。
//   不包含用户偏好（由 SettingsStore 管理）或工程选项（由 EngineeringOptions 提供）。
//
// 依赖：
//   - KeychainHelper：API Key 安全存储
//
// 架构角色：
//   由 AppDelegate 调用 Config.load() 创建，API Key 传递给 CloudOpenAIService 和 NetworkHealthMonitor。

import Foundation

struct Config {

    let openaiApiKey: String

    static func load() -> Config {
        Log.d("Loading config...")
        let config = Config(openaiApiKey: KeychainHelper.load() ?? "")
        Log.d("Config loaded")
        return config
    }
}
