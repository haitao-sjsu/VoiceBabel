// ServiceTextCleanup.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// GPT-4o-mini 文本优化服务 —— 对语音转录结果进行润色和清理。
//
// 职责：
//   1. 文本润色：通过 Chat Completions API 调用 gpt-4o-mini 清理转录文本
//   2. 三种优化模式：
//      - neutral：自然润色（去填充词、修语法、解决自我修正）
//      - formal：正式风格（商务邮件级别，完整句子，无口语）
//      - casual：口语风格（轻松对话，常用缩写）
//   3. 安全保障：严格保持原语言不翻译，失败时回退到原始文本不丢失
//
// 本文件还定义了 TextCleanupMode 枚举（off/neutral/formal/casual），
// 被 RecordingController 和 SettingsView 共同使用。
//
// 依赖：
//   - Constants：chatCompletionsURL（API 端点）、apiProcessingTimeoutMin/Max（超时参数）
//
// 架构角色：
//   由 AppDelegate 创建，由 RecordingController.outputText() 在转录完成后调用。
//   翻译模式下跳过（翻译结果已经是处理过的文本）。

import Foundation

// MARK: - 文本优化模式枚举

enum TextCleanupMode: String {
    case off = "off"
    case neutral = "neutral"
    case formal = "formal"
    case casual = "casual"

    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .neutral: return "自然润色"
        case .formal: return "正式风格"
        case .casual: return "口语风格"
        }
    }

    static func from(_ string: String) -> TextCleanupMode {
        return TextCleanupMode(rawValue: string) ?? .off
    }
}

// MARK: - 文本优化服务

class ServiceTextCleanup {

    // MARK: - 配置

    /// API 密钥
    private let apiKey: String

    // MARK: - Prompt 模板

    /// 所有模式共享的系统 preamble
    private static let sharedPreamble = """
        You are a text cleanup assistant. Your ONLY job is to clean up speech-to-text output. \
        CRITICAL RULES: \
        1) Do NOT translate - preserve the original language(s) exactly. If the input is Chinese, output Chinese. If mixed Chinese+English, keep both. \
        2) Do NOT add new information or change meaning. \
        3) Output ONLY the cleaned text, no explanations.
        """

    /// 各模式的附加指令
    private static let modeInstructions: [TextCleanupMode: String] = [
        .neutral: """
            Remove filler words (um, uh, like, you know, 那个, 就是, 然后呢, 嗯, 啊). \
            Fix grammar and punctuation. \
            Resolve self-corrections (keep only the correction). \
            Keep the tone unchanged.
            """,
        .formal: """
            Rewrite in formal, professional tone suitable for business emails. \
            Use complete sentences. \
            Avoid colloquialisms and contractions.
            """,
        .casual: """
            Keep it casual and conversational. \
            Use common abbreviations where natural (NP, BTW, ASAP, etc.). \
            Keep it concise and friendly.
            """
    ]

    // MARK: - 初始化

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - 公共方法

    /// 对文本进行优化/清理
    /// - Parameters:
    ///   - text: 原始转录文本
    ///   - mode: 优化模式（不应为 .off，调用前应检查）
    ///   - completion: 完成回调，成功返回优化后的文本，失败返回原始文本
    func cleanup(text: String, mode: TextCleanupMode, audioDuration: TimeInterval = 0, completion: @escaping (Result<String, Error>) -> Void) {
        guard mode != .off else {
            completion(.success(text))
            return
        }

        guard let url = URL(string: Constants.chatCompletionsURL) else {
            Log.e("文本优化: URL 无效")
            completion(.success(text))  // 失败时返回原始文本
            return
        }

        let systemPrompt = ServiceTextCleanup.sharedPreamble + "\n" +
            (ServiceTextCleanup.modeInstructions[mode] ?? "")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let minutes = audioDuration / 60.0
        let timeout = min(max(minutes * 10, Constants.apiProcessingTimeoutMin), Constants.apiProcessingTimeoutMax)
        request.timeoutInterval = timeout

        let payload: [String: Any] = [
            "model": "gpt-4o-mini",
            "temperature": 0.3,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": text
                ]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            Log.e("文本优化: JSON 序列化失败: \(error.localizedDescription)")
            completion(.success(text))  // 失败时返回原始文本
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                Log.e("文本优化: 网络错误: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                Log.e("文本优化: 无效响应")
                completion(.failure(CleanupError.invalidResponse))
                return
            }

            guard let data = data else {
                Log.e("文本优化: 没有返回数据")
                completion(.failure(CleanupError.noData))
                return
            }

            if httpResponse.statusCode != 200 {
                let errorMessage = String(data: data, encoding: .utf8) ?? "未知错误"
                Log.e("文本优化: API 错误 (\(httpResponse.statusCode)): \(errorMessage)")
                completion(.failure(CleanupError.apiError(httpResponse.statusCode, errorMessage)))
                return
            }

            // 解析 Chat Completions 响应 JSON
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    let cleanedText = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    Log.i("文本优化完成: \"\(text)\" → \"\(cleanedText)\"")
                    completion(.success(cleanedText))
                } else {
                    Log.e("文本优化: 响应解码失败")
                    completion(.failure(CleanupError.decodingError))
                }
            } catch {
                Log.e("文本优化: JSON 解析失败: \(error.localizedDescription)")
                completion(.failure(CleanupError.decodingError))
            }
        }

        task.resume()
    }

    // MARK: - 错误类型

    enum CleanupError: Error, LocalizedError {
        case invalidResponse
        case noData
        case apiError(Int, String)
        case decodingError

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "文本优化: 无效的响应"
            case .noData:
                return "文本优化: 没有返回数据"
            case .apiError(let code, let message):
                return "文本优化: API 错误 (\(code)): \(message)"
            case .decodingError:
                return "文本优化: 响应解码失败"
            }
        }
    }
}
