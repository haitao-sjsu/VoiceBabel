// ApiKeyValidator.swift
// VoiceBabel - macOS 菜单栏语音转文字工具
//
// API Key 验证器 —— 通过 OpenAI API 验证密钥有效性。
//
// 职责：
//   调用 GET /v1/models 端点验证 API Key 是否有效。
//   这是 OpenAI 文档中最轻量的认证端点，不消耗 token。
//
// 依赖：
//   - SettingsStore.ApiKeyStatus：验证结果枚举
//
// 架构角色：
//   被 SettingsStore.validateApiKey() 调用。

import Foundation

enum ApiKeyValidator {

    /// 验证 API Key 是否有效
    /// 使用 GET /v1/models 端点（只返回模型列表，不消耗 token）
    static func validate(apiKey: String) async -> SettingsStore.ApiKeyStatus {
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            Log.e("ApiKeyValidator: invalid URL")
            return .invalid(String(localized: "Invalid URL"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                Log.e("ApiKeyValidator: invalid response")
                return .invalid(String(localized: "Invalid response"))
            }

            switch httpResponse.statusCode {
            case 200:
                Log.i("ApiKeyValidator: API key is valid")
                return .valid
            case 401:
                Log.w("ApiKeyValidator: API key invalid or expired")
                return .invalid(String(localized: "API Key invalid or expired"))
            case 403:
                Log.w("ApiKeyValidator: API key insufficient permissions")
                return .invalid(String(localized: "API Key insufficient permissions"))
            case 429:
                // 429 说明 Key 是有效的，只是速率受限
                Log.i("ApiKeyValidator: API key valid (rate limited)")
                return .valid
            default:
                Log.w("ApiKeyValidator: unexpected status \(httpResponse.statusCode)")
                return .invalid(String(localized: "Validation failed (HTTP \(httpResponse.statusCode))"))
            }
        } catch {
            Log.e("ApiKeyValidator: network error: \(error.localizedDescription)")
            return .invalid(String(localized: "Network error: \(error.localizedDescription)"))
        }
    }
}
