// KeychainHelper.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// Keychain 操作封装 —— 安全存储 API Key。
//
// 职责：
//   封装 macOS Keychain Services API，提供 API Key 的保存、读取、删除、存在性检查。
//   使用 kSecClassGenericPassword 存储，service = "com.whisperutil.api"，
//   account = "openai-api-key"。
//
// 依赖：
//   - Security.framework：macOS Keychain Services
//   - Log：日志工具
//
// 架构角色：
//   被 Config.swift、SettingsStore.swift、AppDelegate.swift、RecordingController.swift 引用，
//   作为 API Key 的唯一存储后端。

import Foundation
import Security

enum KeychainHelper {

    private static let service = "com.whisperutil.api"
    private static let defaultAccount = "openai-api-key"

    /// 保存 API Key 到 Keychain
    static func save(apiKey: String, for account: String = defaultAccount) -> Bool {
        guard let data = apiKey.data(using: .utf8) else { return false }

        // 先尝试删除已有条目（避免 errSecDuplicateItem）
        delete(for: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            Log.i("KeychainHelper: saved successfully")
        } else {
            Log.e("Keychain 保存失败: \(status)")
        }
        return status == errSecSuccess
    }

    /// 从 Keychain 读取 API Key
    static func load(for account: String = defaultAccount) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.w("KeychainHelper: load failed, status: \(status)")
            }
            return nil
        }
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    /// 从 Keychain 删除 API Key
    @discardableResult
    static func delete(for account: String = defaultAccount) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 检查 Keychain 中是否存在 API Key
    static func exists(for account: String = defaultAccount) -> Bool {
        return load(for: account) != nil
    }
}
