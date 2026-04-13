// SettingsStore.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 用户设置持久化层 —— UserDefaults 存储 + ObservableObject 发布者。
//
// 职责：
//   1. 管理所有用户可调设置的持久化（读写 UserDefaults）
//   2. 作为 ObservableObject 为 SwiftUI 视图提供双向数据绑定
//   3. 通过 @Published 属性为 AppDelegate 提供 Combine 发布者，实时传播设置变更
//
// 管理的设置项：
//   - defaultApiMode：API 模式（local/cloud/realtime）
//   - whisperLanguage：语音识别语言
//   - playSound：是否播放提示音
//   - autoSendMode：自动发送模式（off/always/smart）
//   - smartModeWaitDuration：智能模式等待时间
//   - textCleanupMode：文本优化模式（off/neutral/formal/casual）
//   - translationTargetLanguage：翻译目标语言
//
// 设计：
//   - @MainActor 单例模式，确保线程安全
//   - 初始化时从 UserDefaults 读取，fallback 到 UserSettings 硬编码默认值
//   - @Published + didSet 模式：值变更时自动写入 UserDefaults 并通知订阅者
//
// 依赖：
//   - UserSettings：提供 fallback 默认值
//
// 架构角色：
//   - SwiftUI SettingsView 通过 @ObservedObject 绑定
//   - AppDelegate 通过 Combine $publisher 订阅变更，驱动 RecordingController 和 StatusBarController

import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    // Keys
    private enum Keys {
        static let defaultApiMode = "defaultApiMode"
        static let whisperLanguage = "whisperLanguage"
        static let playSound = "playSound"
        static let autoSendMode = "autoSendMode"
        static let smartModeWaitDuration = "smartModeWaitDuration"
        static let textCleanupMode = "textCleanupMode"
        static let translationTargetLanguage = "translationTargetLanguage"
    }

    @Published var defaultApiMode: String {
        didSet { defaults.set(defaultApiMode, forKey: Keys.defaultApiMode) }
    }
    @Published var whisperLanguage: String {
        didSet { defaults.set(whisperLanguage, forKey: Keys.whisperLanguage) }
    }
    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Keys.playSound) }
    }
    @Published var autoSendMode: String {
        didSet { defaults.set(autoSendMode, forKey: Keys.autoSendMode) }
    }
    @Published var smartModeWaitDuration: TimeInterval {
        didSet { defaults.set(smartModeWaitDuration, forKey: Keys.smartModeWaitDuration) }
    }
    @Published var textCleanupMode: String {
        didSet { defaults.set(textCleanupMode, forKey: Keys.textCleanupMode) }
    }
    @Published var translationTargetLanguage: String {
        didSet { defaults.set(translationTargetLanguage, forKey: Keys.translationTargetLanguage) }
    }

    private init() {
        // Load from UserDefaults, fall back to UserSettings defaults
        self.defaultApiMode = defaults.object(forKey: Keys.defaultApiMode) as? String ?? UserSettings.defaultApiMode
        self.whisperLanguage = defaults.object(forKey: Keys.whisperLanguage) as? String ?? UserSettings.whisperLanguage
        self.playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? UserSettings.playSound
        self.autoSendMode = defaults.object(forKey: Keys.autoSendMode) as? String ?? UserSettings.autoSendMode
        self.smartModeWaitDuration = defaults.object(forKey: Keys.smartModeWaitDuration) as? TimeInterval ?? UserSettings.smartModeWaitDuration
        self.textCleanupMode = defaults.object(forKey: Keys.textCleanupMode) as? String ?? UserSettings.textCleanupMode
        self.translationTargetLanguage = defaults.object(forKey: Keys.translationTargetLanguage) as? String ?? "en"
    }
}
