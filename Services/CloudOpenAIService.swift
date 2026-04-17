// CloudOpenAIService.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// OpenAI Whisper HTTP 客户端 —— 提供云端语音转写和翻译能力。
//
// 职责：
//   1. transcribe() → /v1/audio/transcriptions（gpt-4o-transcribe，语音转文字，保持原语言）
//   2. chatTranslate() → Chat Completions API（GPT 文本翻译，支持多目标语言）
//   3. 手动构造 multipart/form-data 请求体（sendRequest 通用方法）
//   4. 根据音频时长动态计算处理超时：公式 = min(max(分钟数×10, 5s), 90s)
//
// 核心流程：
//   sendRequest() 是统一的 HTTP 请求方法，处理：
//   - multipart/form-data 构建（文件、模型、语言、prompt 等字段）
//   - 动态超时（基于音频时长）
//   - 自定义 URLSession（避免共享 session 的超时冲突）
//   - 错误分类（WhisperError：网络错误可触发本地回退，API 错误不回退）
//
// 依赖：
//   - EngineeringOptions：API 端点 URL（whisperTranscribeURL, chatCompletionsURL）、超时参数、模型名
//   - AudioRecorder.AudioFormat：音频格式信息（文件名、Content-Type）
//
// 架构角色：
//   由 AppDelegate 创建（传入 API key、model、language），由 RecordingController 在
//   cloud 模式和翻译模式下调用。网络错误时 RecordingController 可触发本地回退。

import Foundation

class CloudOpenAIService {

    // MARK: - 配置

    /// API 密钥
    private let apiKey: String

    /// 使用的模型
    private let model: String

    /// 语言代码（如 "zh", "en"，空字符串表示自动检测）
    var language: String

    /// 转录 API 端点
    private let transcribeURL = URL(string: EngineeringOptions.whisperTranscribeURL)!

    // MARK: - 初始化

    init(apiKey: String, model: String, language: String) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
    }

    // MARK: - 公共方法

    /// 转录音频（语音转文字，保持原语言）
    /// - Parameters:
    ///   - audioData: 音频数据
    ///   - format: 音频格式
    ///   - audioDuration: 音频时长（秒），用于动态计算处理超时
    ///   - completion: 完成回调，返回识别文本或错误
    func transcribe(audioData: Data, format: AudioRecorder.AudioFormat, audioDuration: TimeInterval = 0, completion: @escaping (Result<String, Error>) -> Void) {
        Log.i(LocaleManager.shared.logLocalized("Cloud transcription: starting, audio size:") + " \(audioData.count) bytes, format: \(format.filename)")
        sendRequest(
            url: transcribeURL,
            audioData: audioData,
            format: format,
            includeLanguage: true,
            overrideModel: nil,
            audioDuration: audioDuration,
            completion: completion
        )
    }

    /// 调用 Chat Completions API 将文本翻译为目标语言
    /// - Parameters:
    ///   - text: 待翻译文本
    ///   - targetLanguage: 目标语言代码（如 "en", "zh", "ja"）
    ///   - completion: 完成回调
    func chatTranslate(text: String, targetLanguage: String, completion: @escaping (Result<String, Error>) -> Void) {
        let languageName = Self.languageDisplayName(for: targetLanguage)
        Log.i(LocaleManager.shared.logLocalized("GPT translation: translating to") + " \(languageName)")

        guard let url = URL(string: EngineeringOptions.chatCompletionsURL) else {
            completion(.failure(WhisperError.invalidResponse))
            return
        }

        // 使用自定义 session，与 sendRequest() 保持一致
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = EngineeringOptions.apiProcessingTimeoutMax
        let session = URLSession(configuration: sessionConfig)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": EngineeringOptions.chatTranslationModel,
            "temperature": 0.3,
            "messages": [
                [
                    "role": "system",
                    "content": "You are a translator. Translate the following text to \(languageName). Output ONLY the translation, nothing else."
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
            Log.e(LocaleManager.shared.logLocalized("GPT translation: JSON serialization failed:") + " \(error.localizedDescription)")
            completion(.failure(WhisperError.networkError("JSON serialization failed: \(error.localizedDescription)")))
            return
        }

        let task = session.dataTask(with: request) { data, response, error in
            session.finishTasksAndInvalidate()

            if let error = error {
                Log.e(LocaleManager.shared.logLocalized("GPT translation: network error:") + " \(error.localizedDescription)")
                completion(.failure(WhisperError.networkError(error.localizedDescription)))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                Log.e(LocaleManager.shared.logLocalized("GPT translation: invalid response"))
                completion(.failure(WhisperError.invalidResponse))
                return
            }

            guard let data = data else {
                Log.e(LocaleManager.shared.logLocalized("GPT translation: no data returned"))
                completion(.failure(WhisperError.noData))
                return
            }

            if httpResponse.statusCode != 200 {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                Log.e(LocaleManager.shared.logLocalized("GPT translation: API error") + " (\(httpResponse.statusCode)): \(errorMessage)")
                completion(.failure(WhisperError.apiError(httpResponse.statusCode, errorMessage)))
                return
            }

            // Parse Chat Completions response JSON
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    Log.i(LocaleManager.shared.logLocalized("GPT translation: complete, text length:") + " \(content.count)")
                    completion(.success(content))
                } else {
                    Log.e(LocaleManager.shared.logLocalized("GPT translation: response decoding failed"))
                    completion(.failure(WhisperError.decodingError))
                }
            } catch {
                Log.e(LocaleManager.shared.logLocalized("GPT translation: JSON parse failed:") + " \(error.localizedDescription)")
                completion(.failure(WhisperError.decodingError))
            }
        }

        task.resume()
    }

    // MARK: - 私有方法

    /// 发送 multipart/form-data 请求到 Whisper API
    ///
    /// HTTP 请求体结构（multipart/form-data）：
    ///   --boundary
    ///   Content-Disposition: form-data; name="file"; filename="audio.m4a"
    ///   Content-Type: audio/mp4
    ///   [音频二进制数据]
    ///   --boundary
    ///   Content-Disposition: form-data; name="model"
    ///   [模型名称]
    ///   --boundary--
    /// 根据音频时长计算处理超时时间
    /// 公式：音频时长(分钟) × 10，限制在 [min, max] 范围内
    func calculateProcessingTimeout(audioDuration: TimeInterval) -> TimeInterval {
        let minutes = audioDuration / 60.0
        let timeout = minutes * 10
        return min(max(timeout, EngineeringOptions.apiProcessingTimeoutMin), EngineeringOptions.apiProcessingTimeoutMax)
    }

    private func sendRequest(
        url: URL,
        audioData: Data,
        format: AudioRecorder.AudioFormat,
        includeLanguage: Bool,
        overrideModel: String?,
        audioDuration: TimeInterval = 0,
        prompt: String? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let effectiveModel = overrideModel ?? model
        // 创建 multipart/form-data 请求
        let boundary = UUID().uuidString

        // 动态超时：根据音频时长计算，短音频快速失败，长音频耐心等待
        let timeout = calculateProcessingTimeout(audioDuration: audioDuration)
        Log.d("API timeout: \(String(format: "%.0f", timeout))s (audio duration \(String(format: "%.1f", audioDuration))s)")

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: sessionConfig)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // 构建请求体
        var body = Data()

        // 添加文件（使用实际的音频格式）
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(format.filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(format.contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // 添加模型参数
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(effectiveModel)\r\n".data(using: .utf8)!)

        // 添加响应格式（简单文本）
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        // 添加语言参数（如果需要）
        // 用户明确指定语言时发送；为空则不发送，让模型自动检测
        // "ui" 表示跟随界面语言，从 LocaleManager 推导
        if includeLanguage {
            let effectiveLanguage: String?
            if language.isEmpty {
                effectiveLanguage = nil  // 不发送 language 参数，让模型自动检测
            } else if language == "ui" {
                // "ui" 跟随界面语言；无法解析时 fall through 到自动检测
                // 不能硬编码 "en" 兜底 —— 那样用户说中文会得到英文转录
                if let interfaceCode = LocaleManager.shared.currentLocale.language.languageCode?.identifier {
                    effectiveLanguage = LocaleManager.whisperCode(for: interfaceCode)
                } else {
                    Log.w("UI language code unresolvable, falling back to auto-detect")
                    effectiveLanguage = nil
                }
            } else {
                effectiveLanguage = LocaleManager.whisperCode(for: language)
            }
            if let lang = effectiveLanguage {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(lang)\r\n".data(using: .utf8)!)
                Log.d("Whisper API language: \(lang)")
            } else {
                Log.d("Whisper API language: auto-detect (not sent)")
            }
        }

        // 添加 prompt 参数（如果指定）
        if let prompt = prompt {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(prompt)\r\n".data(using: .utf8)!)
        }

        // 结束边界
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        // 发送请求
        let task = session.dataTask(with: request) { data, response, error in
            // 释放自定义 session
            session.finishTasksAndInvalidate()

            // 处理网络错误
            if let error = error {
                Log.e(LocaleManager.shared.logLocalized("Cloud transcription: network error:") + " \(error.localizedDescription)")
                completion(.failure(WhisperError.networkError(error.localizedDescription)))
                return
            }

            // 检查 HTTP 响应
            guard let httpResponse = response as? HTTPURLResponse else {
                Log.e(LocaleManager.shared.logLocalized("Cloud transcription: invalid response"))
                completion(.failure(WhisperError.invalidResponse))
                return
            }

            // 检查响应数据
            guard let data = data else {
                Log.e(LocaleManager.shared.logLocalized("Cloud transcription: no data returned"))
                completion(.failure(WhisperError.noData))
                return
            }

            // 处理错误状态码
            if httpResponse.statusCode != 200 {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                Log.e(LocaleManager.shared.logLocalized("Cloud transcription: API error") + " (\(httpResponse.statusCode)): \(errorMessage)")
                completion(.failure(WhisperError.apiError(httpResponse.statusCode, errorMessage)))
                return
            }

            // Parse response (text format returns text directly)
            if let text = String(data: data, encoding: .utf8) {
                Log.i(LocaleManager.shared.logLocalized("Cloud transcription: complete, text length:") + " \(text.count)")
                completion(.success(text))
            } else {
                Log.e(LocaleManager.shared.logLocalized("Cloud transcription: response decoding failed"))
                completion(.failure(WhisperError.decodingError))
            }
        }

        task.resume()
    }

    // MARK: - 语言代码映射

    /// 将语言代码映射为英文语言名称（用于 GPT prompt）
    static func languageDisplayName(for code: String) -> String {
        switch code {
        case "en": return "English"
        case "zh": return "Simplified Chinese"
        case "zh-Hant": return "Traditional Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        case "pt": return "Portuguese"
        case "ru": return "Russian"
        case "ar": return "Arabic"
        case "hi": return "Hindi"
        case "it": return "Italian"
        default: return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        }
    }

    // MARK: - 错误类型

    enum WhisperError: Error, LocalizedError {
        case networkError(String)
        case invalidResponse
        case noData
        case apiError(Int, String)
        case decodingError

        var errorDescription: String? {
            switch self {
            case .networkError(let message):
                return String(localized: "Network error: \(message)")
            case .invalidResponse:
                return String(localized: "Invalid response")
            case .noData:
                return String(localized: "No data returned")
            case .apiError(let code, let message):
                return String(localized: "API error (\(code)): \(message)")
            case .decodingError:
                return String(localized: "Response decoding failed")
            }
        }
    }
}
