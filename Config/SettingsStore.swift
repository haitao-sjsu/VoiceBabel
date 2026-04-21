// SettingsStore.swift
// VoiceBabel - macOS 菜单栏语音转文字工具
//
// 用户设置持久化层 —— UserDefaults 存储 + ObservableObject 发布者。
//
// 职责：
//   1. 管理所有用户可调设置的持久化（读写 UserDefaults）
//   2. 作为 ObservableObject 为 SwiftUI 视图提供双向数据绑定
//   3. 通过 @Published 属性为 AppDelegate 提供 Combine 发布者，实时传播设置变更
//
// 管理的设置项：
//   - whisperLanguage：语音识别语言
//   - playSound：是否播放提示音
//   - autoSendMode：自动发送模式（off/always/delayed）
//   - delayedSendDuration：延迟发送模式等待时间
//   - translationTargetLanguage：翻译目标语言
//
// 设计：
//   - @MainActor 单例模式，确保线程安全
//   - 初始化时从 UserDefaults 读取，fallback 到 SettingsDefaults 硬编码默认值
//   - @Published + didSet 模式：值变更时自动写入 UserDefaults 并通知订阅者
//
// 依赖：
//   - SettingsDefaults：提供 fallback 默认值
//
// 架构角色：
//   - SwiftUI SettingsView 通过 @ObservedObject 绑定
//   - AppDelegate 通过 Combine $publisher 订阅变更，驱动 AppController 和 StatusBarController

import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    enum ApiKeyStatus {
        case unchecked
        case valid
        case invalid(String)
    }

    private let defaults = UserDefaults.standard

    // Keys
    private enum Keys {
        static let transcriptionPriority = "transcriptionPriority"
        static let translationEnginePriority = "translationEnginePriority"
        static let transcriptionEnabled = "transcriptionEnabled"
        static let translationEngineEnabled = "translationEngineEnabled"
        static let whisperLanguage = "whisperLanguage"
        static let playSound = "playSound"
        static let autoSendMode = "autoSendMode"
        static let delayedSendDuration = "delayedSendDuration"
        static let translationTargetLanguage = "translationTargetLanguage"
        static let appLanguage = "appLanguage"
    }

    @Published var transcriptionPriority: [String] {
        didSet { defaults.set(transcriptionPriority, forKey: Keys.transcriptionPriority) }
    }
    @Published var translationEnginePriority: [String] {
        didSet { defaults.set(translationEnginePriority, forKey: Keys.translationEnginePriority) }
    }
    /// 转录引擎主观启用状态（id → 是否启用）。与 `transcriptionPriority` 正交：
    /// 即便一个引擎在优先级数组里，若在此为 false 也会被 AppDelegate 过滤掉。
    @Published var transcriptionEnabled: [String: Bool] {
        didSet { defaults.set(transcriptionEnabled, forKey: Keys.transcriptionEnabled) }
    }
    /// 翻译引擎主观启用状态，同上。
    @Published var translationEngineEnabled: [String: Bool] {
        didSet { defaults.set(translationEngineEnabled, forKey: Keys.translationEngineEnabled) }
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
    @Published var delayedSendDuration: TimeInterval {
        didSet { defaults.set(delayedSendDuration, forKey: Keys.delayedSendDuration) }
    }
    @Published var translationTargetLanguage: String {
        didSet { defaults.set(translationTargetLanguage, forKey: Keys.translationTargetLanguage) }
    }
    @Published var appLanguage: String {
        didSet {
            defaults.set(appLanguage, forKey: Keys.appLanguage)
            LocaleManager.shared.setLocale(appLanguage)
        }
    }

    @Published var apiKeyInput: String = ""
    @Published var hasApiKey: Bool = false
    @Published var maskedApiKey: String = ""
    @Published var apiKeyStatus: ApiKeyStatus = .unchecked
    @Published var isValidatingKey: Bool = false
    @Published var apiKeyVersion: Int = 0

    private init() {
        // Load priorities into local vars first — Swift forbids reading `self.*` before
        // every stored property has an initial value, so we can't iterate
        // `self.transcriptionPriority` for backfill until the whole init is done.
        let transcriptionPriority = (defaults.object(forKey: Keys.transcriptionPriority) as? [String])
            ?? SettingsDefaults.transcriptionPriority
        let translationEnginePriority = (defaults.object(forKey: Keys.translationEnginePriority) as? [String])
            ?? SettingsDefaults.translationEnginePriority
        self.transcriptionPriority = transcriptionPriority
        self.translationEnginePriority = translationEnginePriority

        // 主观启用字典 —— 对优先级数组里但字典缺失的 id 回填为 true（新引擎默认启用）。
        var tEnabled = (defaults.object(forKey: Keys.transcriptionEnabled) as? [String: Bool])
            ?? SettingsDefaults.transcriptionEnabled
        for id in transcriptionPriority where tEnabled[id] == nil { tEnabled[id] = true }
        self.transcriptionEnabled = tEnabled

        var trEnabled = (defaults.object(forKey: Keys.translationEngineEnabled) as? [String: Bool])
            ?? SettingsDefaults.translationEngineEnabled
        for id in translationEnginePriority where trEnabled[id] == nil { trEnabled[id] = true }
        self.translationEngineEnabled = trEnabled

        self.whisperLanguage = defaults.object(forKey: Keys.whisperLanguage) as? String ?? SettingsDefaults.whisperLanguage
        self.playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? SettingsDefaults.playSound
        self.autoSendMode = defaults.object(forKey: Keys.autoSendMode) as? String ?? SettingsDefaults.autoSendMode
        self.delayedSendDuration = defaults.object(forKey: Keys.delayedSendDuration) as? TimeInterval ?? SettingsDefaults.delayedSendDuration
        self.translationTargetLanguage = defaults.object(forKey: Keys.translationTargetLanguage) as? String ?? SettingsDefaults.translationTargetLanguage
        self.appLanguage = defaults.object(forKey: Keys.appLanguage) as? String ?? "system"

        // Apply saved locale
        LocaleManager.shared.setLocale(self.appLanguage)

        // 初始化 API Key 状态
        self.hasApiKey = KeychainHelper.exists()
        if let key = KeychainHelper.load() {
            self.maskedApiKey = Self.maskApiKey(key)
        }

        // 日志：记录加载后的主观启用状态，便于排查"为什么引擎未被尝试"类问题。
        Log.i("SettingsStore loaded transcriptionEnabled=\(tEnabled), translationEngineEnabled=\(trEnabled)")
    }

    // MARK: - API Key 管理

    /// 保存 API Key 到 Keychain
    func saveApiKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if KeychainHelper.save(apiKey: key) {
            hasApiKey = true
            maskedApiKey = Self.maskApiKey(key)
            apiKeyInput = ""
            apiKeyStatus = .unchecked
            apiKeyVersion += 1
            Log.i(LocaleManager.shared.logLocalized("API Key saved to Keychain"))
        } else {
            apiKeyStatus = .invalid(String(localized: "Save failed, please retry"))
            Log.e(LocaleManager.shared.logLocalized("API Key save to Keychain failed"))
        }
    }

    /// 保存并立即验证 API Key
    func saveAndValidateApiKey() {
        saveApiKey()
        if hasApiKey { validateApiKey() }
    }

    /// 清除 API Key
    func clearApiKey() {
        KeychainHelper.delete()
        hasApiKey = false
        maskedApiKey = ""
        apiKeyStatus = .unchecked
        apiKeyVersion += 1
        Log.i(LocaleManager.shared.logLocalized("API Key cleared from Keychain"))
    }

    /// 验证 API Key（异步调用 /v1/models）
    func validateApiKey() {
        guard let key = KeychainHelper.load(), !key.isEmpty else {
            apiKeyStatus = .invalid(String(localized: "API Key not set"))
            return
        }
        isValidatingKey = true
        apiKeyStatus = .unchecked
        Task {
            let result = await ApiKeyValidator.validate(apiKey: key)
            await MainActor.run {
                self.isValidatingKey = false
                self.apiKeyStatus = result
            }
        }
    }

    /// 遮盖 API Key，仅显示最后 4 位
    private static func maskApiKey(_ key: String) -> String {
        guard key.count > 4 else { return "****" }
        let suffix = String(key.suffix(4))
        return "*****\(suffix)"
    }
}
