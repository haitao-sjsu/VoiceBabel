// CloudOpenAIService.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// OpenAI Whisper HTTP 客户端 —— 提供云端语音转写和翻译能力。
//
// 职责：
//   1. transcribe() → /v1/audio/transcriptions（gpt-4o-transcribe，语音转文字，保持原语言）
//      - 内联 multipart/form-data 请求构建（无共享 sendRequest 方法）
//      - 返回原始文本，不做裁剪/标签过滤（由 TranscriptionManager 负责后处理）
//   2. chatTranslate() → Chat Completions API（GPT 文本翻译，支持多目标语言）
//   3. 共享 HTTP 执行路径：executeRequest() 统一处理 session 生命周期、错误映射与日志。
//   4. 根据音频时长动态计算处理超时：公式 = min(max(分钟数×10, 5s), 90s)
//
// 语言参数契约（重要）：
//   `transcribe(..., language:)` 中的 `language` 由调用方（TranscriptionManager）解析完毕，
//   本服务只做 **标准化**（`LocaleManager.whisperCode(for:)`），不做兜底。
//   - 空字符串 ""  → 不发送 language 字段，让服务端自动检测
//   - 非空字符串 → 标准化后作为 Whisper API 的 `language` 字段发送
//   禁止在此处插入任何 "ui"/"en"/"zh" 之类的回退（见 Services/CLAUDE.md）。
//
// 依赖：
//   - EngineeringOptions：API 端点 URL（whisperTranscribeURL, chatCompletionsURL）、超时参数、模型名
//   - AudioEncoder：音频编码（Float32 采样 → M4A/WAV）及格式信息（文件名、Content-Type）
//
// 架构角色：
//   由 AppDelegate 创建（传入 API key、model），在 async/throws 的调用链中被
//   TranscriptionManager / TranslationManager 直接 await。语言不再作为构造参数存储。

import Foundation

class CloudOpenAIService {

    // MARK: - 配置

    /// API 密钥
    private let apiKey: String

    /// 使用的模型
    private let model: String

    /// 转录 API 端点
    private let transcribeURL = URL(string: EngineeringOptions.whisperTranscribeURL)!

    // MARK: - 初始化

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: - 公共方法

    /// 转录原始音频采样（Float32 PCM → 编码 → 上传）
    /// - Parameters:
    ///   - samples: Float32 PCM 采样数据（值域 -1.0 ~ 1.0）
    ///   - audioDuration: 音频时长（秒），用于动态计算处理超时
    ///   - language: 已解析的语言代码（由 TranscriptionManager 解析）。
    ///               空字符串 `""` 表示自动检测（不发送 language 字段）。
    ///               非空字符串将被 `LocaleManager.whisperCode(for:)` 标准化后发送。
    /// - Returns: API 返回的原始文本（未做 trim / 标签过滤，由 Manager 统一后处理）
    func transcribe(samples: [Float], audioDuration: TimeInterval, language: String) async throws -> String {
        let lm = LocaleManager.shared

        // 1. 编码音频
        let encoded: AudioEncoder.EncodingResult?
        if EngineeringOptions.enableAudioCompression {
            encoded = AudioEncoder.encodeToM4A(samples: samples)
        } else {
            encoded = AudioEncoder.encodeToWAV(samples: samples)
        }
        guard let encoded = encoded else {
            Log.e(lm.logLocalized("Audio encoding failed"))
            throw WhisperError.encodingFailed
        }
        Log.i(lm.logLocalized("Audio encoded:") + " \(encoded.format), \(encoded.data.count) bytes")

        // 2. 构建 multipart/form-data 请求
        //
        // HTTP 请求体结构（multipart/form-data）：
        //   --boundary
        //   Content-Disposition: form-data; name="file"; filename="audio.m4a"
        //   Content-Type: audio/mp4
        //   [音频二进制数据]
        //   --boundary
        //   Content-Disposition: form-data; name="model"
        //   [模型名称]
        //   --boundary
        //   Content-Disposition: form-data; name="response_format"
        //   text
        //   --boundary
        //   Content-Disposition: form-data; name="language"   (可选)
        //   [语言代码]
        //   --boundary--
        let boundary = UUID().uuidString

        var request = URLRequest(url: transcribeURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // 2a. 文件字段（使用实际的音频格式名/Content-Type）
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(encoded.format.filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(encoded.format.contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(encoded.data)
        body.append("\r\n".data(using: .utf8)!)

        // 2b. 模型字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // 2c. 响应格式（text 直接返回纯文本）
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        // 2d. 语言字段（可选）
        // 调用方传入的 language 已是解析后的结果（空串 = 自动检测）。
        // 仅做标准化，不做任何兜底（Services/CLAUDE.md 硬性规则）。
        if language.isEmpty {
            Log.d("Whisper API language: auto-detect (not sent)")
        } else {
            let normalized = LocaleManager.whisperCode(for: language)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(normalized)\r\n".data(using: .utf8)!)
            Log.d("Whisper API language: \(normalized)")
        }

        // 2e. 结束边界
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        // 3. 发送请求（动态超时：短音频快速失败，长音频耐心等待）
        let timeout = calculateProcessingTimeout(audioDuration: audioDuration)
        Log.d("API timeout: \(String(format: "%.0f", timeout))s (audio duration \(String(format: "%.1f", audioDuration))s)")

        let data = try await executeRequest(
            request,
            timeout: timeout,
            errorContext: "Cloud transcription"
        )

        // 4. 解析响应（response_format=text 直接返回纯文本）
        //    不做 trim / 标签过滤 —— 由 TranscriptionManager 统一后处理。
        guard let text = String(data: data, encoding: .utf8) else {
            Log.e(lm.logLocalized("Cloud transcription: response decoding failed"))
            throw WhisperError.decodingError
        }
        Log.i(lm.logLocalized("Cloud transcription: complete, text length:") + " \(text.count)")
        return text
    }

    /// 调用 Chat Completions API 将文本翻译为目标语言
    /// - Parameters:
    ///   - text: 待翻译文本
    ///   - targetLanguage: 目标语言代码（如 "en", "zh", "ja"）
    /// - Returns: GPT 翻译后的原始文本（未做 trim，由 Manager 统一后处理）
    func chatTranslate(text: String, targetLanguage: String) async throws -> String {
        let lm = LocaleManager.shared
        let languageName = Self.languageDisplayName(for: targetLanguage)
        Log.i(lm.logLocalized("GPT translation: translating to") + " \(languageName)")

        guard let url = URL(string: EngineeringOptions.chatCompletionsURL) else {
            Log.e(lm.logLocalized("GPT translation: invalid response"))
            throw WhisperError.invalidResponse
        }

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
            Log.e(lm.logLocalized("GPT translation: JSON serialization failed:") + " \(error.localizedDescription)")
            throw WhisperError.networkError("JSON serialization failed: \(error.localizedDescription)")
        }

        // Chat 翻译没有音频时长依据，使用 apiProcessingTimeoutMax 作为上限超时。
        let data = try await executeRequest(
            request,
            timeout: EngineeringOptions.apiProcessingTimeoutMax,
            errorContext: "GPT translation"
        )

        // 解析 Chat Completions 响应 JSON
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                Log.e(lm.logLocalized("GPT translation: response decoding failed"))
                throw WhisperError.decodingError
            }
            Log.i(lm.logLocalized("GPT translation: complete, text length:") + " \(content.count)")
            return content
        } catch let error as WhisperError {
            throw error
        } catch {
            Log.e(lm.logLocalized("GPT translation: JSON parse failed:") + " \(error.localizedDescription)")
            throw WhisperError.decodingError
        }
    }

    // MARK: - 私有方法

    /// 根据音频时长计算处理超时时间。
    /// 公式：音频时长(分钟) × 10，限制在 [apiProcessingTimeoutMin, apiProcessingTimeoutMax] 范围内。
    /// 仅用于 transcribe()；chatTranslate() 无音频依据，直接使用 max 上限。
    private func calculateProcessingTimeout(audioDuration: TimeInterval) -> TimeInterval {
        let minutes = audioDuration / 60.0
        let timeout = minutes * 10
        return min(max(timeout, EngineeringOptions.apiProcessingTimeoutMin), EngineeringOptions.apiProcessingTimeoutMax)
    }

    /// 共享 HTTP 执行路径 —— 统一的 session 生命周期、错误映射与上下文日志。
    ///
    /// - Parameters:
    ///   - request: 已构造好的 URLRequest（调用方负责 body / headers）
    ///   - timeout: 单次请求超时（秒），用于 URLSessionConfiguration.timeoutIntervalForRequest
    ///   - errorContext: 日志前缀（如 "Cloud transcription" / "GPT translation"），便于定位失败来源
    /// - Returns: HTTP 200 时返回响应 Data；其它情况抛出 WhisperError
    private func executeRequest(
        _ request: URLRequest,
        timeout: TimeInterval,
        errorContext: String
    ) async throws -> Data {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: sessionConfig)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Log.e("\(errorContext): network error: \(error.localizedDescription)")
            throw WhisperError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Log.e("\(errorContext): invalid response")
            throw WhisperError.invalidResponse
        }

        // 注意：URLSession.data(for:) 正常情况下不会返回空 Data，
        // 但保留 noData 分支以覆盖极端边界（0 字节 body + 200 状态码）。
        guard !data.isEmpty else {
            Log.e("\(errorContext): no data returned")
            throw WhisperError.noData
        }

        if httpResponse.statusCode != 200 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            Log.e("\(errorContext): API error (\(httpResponse.statusCode)): \(errorMessage)")
            throw WhisperError.apiError(httpResponse.statusCode, errorMessage)
        }

        return data
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
        case encodingFailed

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
            case .encodingFailed:
                return String(localized: "Audio encoding failed")
            }
        }
    }
}
