// ServiceRealtimeOpenAI.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// OpenAI Realtime WebSocket 流式转写服务 —— 边录边转的实时语音识别。
//
// 职责：
//   1. WebSocket 生命周期管理：disconnected → connecting → connected → configured → disconnected
//   2. 转录会话配置：通过 transcription_session.update 事件配置模型和 VAD 参数
//   3. 音频流式传输：PCM16 24kHz → base64 编码 → input_audio_buffer.append 事件
//   4. 转录结果分发：
//      - onTranscriptionDelta：增量文字片段（实时逐词显示）
//      - onTranscriptionComplete：一段话的完整转录结果
//   5. Server VAD（服务器端语音活动检测）：阈值 0.5，静音 500ms 自动断句
//
// WebSocket 消息协议（GA 版 intent=transcription 模式）：
//   发送：transcription_session.update, input_audio_buffer.append/commit
//   接收：transcription_session.created/updated,
//         conversation.item.input_audio_transcription.delta/completed,
//         input_audio_buffer.speech_started/stopped, error
//
// 依赖：
//   - EngineeringOptions：realtimeWebSocketURL（WebSocket 端点）、whisperModel（转录模型名称）
//   - URLSessionWebSocketDelegate：WebSocket 连接事件
//
// 架构角色：
//   由 AppDelegate 创建，由 RecordingController 在 realtime 模式下调用。
//   RecordingController 负责协调 AudioRecorder 的流式输出与本服务的音频输入。
//
// 限制：
//   仅支持转录，不支持翻译。

import Foundation

/// Realtime API 连接状态
enum RealtimeConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case configured
}

class ServiceRealtimeOpenAI: NSObject {

    // MARK: - 回调

    /// 转录增量的回调（实时显示）
    var onTranscriptionDelta: ((String) -> Void)?

    /// 转录完成的回调（最终结果，可选使用）
    var onTranscriptionComplete: ((String) -> Void)?

    /// 错误回调
    var onError: ((Error) -> Void)?

    /// 连接状态变化回调
    var onConnectionStateChange: ((RealtimeConnectionState) -> Void)?

    // MARK: - 私有属性

    private let apiKey: String
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var connectionState: RealtimeConnectionState = .disconnected

    /// 累积的转录结果
    private var accumulatedTranscription: String = ""

    /// 语言设置（如 "zh", "en"，空字符串表示自动检测）
    private var language: String = ""

    /// WebSocket 端点（GA 版转录专用模式，使用 gpt-4o-transcribe）
    private let realtimeURL = EngineeringOptions.realtimeWebSocketURL

    // MARK: - 初始化

    init(apiKey: String, language: String) {
        self.apiKey = apiKey
        self.language = language
        super.init()
    }

    // MARK: - 公共方法

    /// 建立 WebSocket 连接
    func connect() {
        guard connectionState == .disconnected else {
            Log.w("Realtime: 已经连接或正在连接中")
            return
        }

        Log.i("Realtime: 正在连接 WebSocket... URL: \(realtimeURL)")
        connectionState = .connecting
        onConnectionStateChange?(.connecting)

        guard let url = URL(string: realtimeURL) else {
            Log.e("Realtime: 无效的 URL: \(realtimeURL)")
            let error = RealtimeError.invalidURL
            onError?(error)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        Log.d("Realtime: 请求头已设置 (Authorization + OpenAI-Beta)")

        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        webSocket = urlSession?.webSocketTask(with: request)
        webSocket?.resume()
        Log.d("Realtime: WebSocket task 已启动")

        // 开始接收消息
        receiveMessage()
    }

    /// 配置转录会话
    /// 使用 transcription_session.update 事件（intent=transcription 模式专用）
    func configureSession(language: String) {
        // 转录模型配置
        var transcriptionConfig: [String: Any] = [
            "model": EngineeringOptions.whisperModel
        ]
        if !language.isEmpty {
            transcriptionConfig["language"] = language
        }

        // 启用服务器端语音活动检测（VAD）
        let turnDetectionConfig: [String: Any] = [
            "type": "server_vad",
            "threshold": 0.5,
            "prefix_padding_ms": 300,
            "silence_duration_ms": 500
        ]

        // transcription_session.update 的配置格式
        let sessionConfig: [String: Any] = [
            "type": "transcription_session.update",
            "session": [
                "input_audio_format": "pcm16",
                "input_audio_transcription": transcriptionConfig,
                "turn_detection": turnDetectionConfig
            ]
        ]

        // 打印完整的配置 JSON 用于调试
        if let jsonData = try? JSONSerialization.data(withJSONObject: sessionConfig, options: .prettyPrinted),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            Log.d("Realtime: 发送会话配置:\n\(jsonStr)")
        }

        sendJSON(sessionConfig)
        Log.i("Realtime: 已发送转录会话配置（gpt-4o-transcribe，语言: \(language.isEmpty ? "自动" : language)）")
    }

    /// 发送音频块（PCM 16-bit 数据）
    /// - Parameter data: PCM 16-bit 音频数据
    func sendAudioChunk(_ data: Data) {
        guard connectionState == .configured else {
            return
        }

        let base64Audio = data.base64EncodedString()
        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]

        sendJSON(message)
    }

    /// 提交音频缓冲区（表示音频结束）
    func commitAudio() {
        guard connectionState == .configured else {
            return
        }

        let message: [String: Any] = [
            "type": "input_audio_buffer.commit"
        ]

        sendJSON(message)
        Log.i("Realtime: 已提交音频缓冲区")
    }

    /// 断开连接
    func disconnect() {
        guard connectionState != .disconnected else { return }
        connectionState = .disconnected

        Log.i("Realtime: 正在断开连接...")
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        accumulatedTranscription = ""
        onConnectionStateChange?(.disconnected)
    }

    /// 重置累积的转录结果
    func resetTranscription() {
        accumulatedTranscription = ""
    }

    // MARK: - 私有方法

    /// 发送 JSON 消息
    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: data, encoding: .utf8) else {
            Log.e("Realtime: JSON 序列化失败")
            return
        }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocket?.send(message) { error in
            if let error = error {
                Log.e("Realtime: 发送消息失败 - \(error)")
            }
        }
    }

    /// 递归接收 WebSocket 消息
    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            if case .disconnected = self.connectionState {
                return
            }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage()

            case .failure(let error):
                if case .disconnected = self.connectionState {
                    return
                }
                Log.e("Realtime: 接收消息失败 - \(error)")
                self.connectionState = .disconnected
                DispatchQueue.main.async {
                    self.onConnectionStateChange?(.disconnected)
                    self.onError?(error)
                }
            }
        }
    }

    /// 处理接收到的消息
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseJSONMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseJSONMessage(text)
            }
        @unknown default:
            break
        }
    }

    /// 解析服务器发送的 JSON 消息并分发处理
    ///
    /// GA 版 Realtime API（转录模式）通过 "type" 字段区分消息类型：
    ///   transcription_session.created → 连接成功，发送 transcription_session.update 配置
    ///   transcription_session.updated → 配置完成，可以发送音频
    ///   conversation.item.input_audio_transcription.delta → 转录增量（实时输出的文字片段）
    ///   conversation.item.input_audio_transcription.completed → 一段话的转录完成
    ///   input_audio_buffer.speech_started/stopped → 服务器 VAD 检测到语音开始/结束
    ///   error → API 错误
    private func parseJSONMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            Log.w("Realtime: 无法解析 JSON 消息: \(text.prefix(200))")
            return
        }

        switch type {
        case "transcription_session.created":
            Log.i("Realtime: 转录会话已创建")
            connectionState = .connected
            onConnectionStateChange?(.connected)
            configureSession(language: language)

        case "transcription_session.updated":
            Log.i("Realtime: 转录会话已配置，状态 → configured")
            connectionState = .configured
            onConnectionStateChange?(.configured)

        case "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                accumulatedTranscription += delta
                Log.d("Realtime: 转录增量 - \(delta)")
                DispatchQueue.main.async {
                    self.onTranscriptionDelta?(delta)
                }
            }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                Log.i("Realtime: 一段转录完成 - \(transcript)")
                accumulatedTranscription = ""
                DispatchQueue.main.async {
                    self.onTranscriptionComplete?(transcript)
                }
            }

        case "input_audio_buffer.committed":
            Log.d("Realtime: 音频缓冲区已确认提交")

        case "input_audio_buffer.speech_started":
            Log.d("Realtime: 检测到语音开始")

        case "input_audio_buffer.speech_stopped":
            Log.d("Realtime: 检测到语音结束")

        case "error":
            if let errorInfo = json["error"] as? [String: Any],
               let errorMessage = errorInfo["message"] as? String {
                Log.e("Realtime: API 错误 - \(errorMessage)")
                // 打印完整错误信息用于调试
                if let errorData = try? JSONSerialization.data(withJSONObject: errorInfo, options: .prettyPrinted),
                   let errorStr = String(data: errorData, encoding: .utf8) {
                    Log.e("Realtime: 错误详情:\n\(errorStr)")
                }
                let error = RealtimeError.apiError(errorMessage)
                DispatchQueue.main.async {
                    self.onError?(error)
                }
            }

        default:
            Log.d("Realtime: 收到事件 - \(type)")
        }
    }

    // MARK: - 错误类型

    enum RealtimeError: Error, LocalizedError {
        case invalidURL
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "无效的 WebSocket URL"
            case .apiError(let message):
                return "Realtime API 错误: \(message)"
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension ServiceRealtimeOpenAI: URLSessionWebSocketDelegate {

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Log.i("Realtime: WebSocket 连接已建立")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "无"
        Log.w("Realtime: WebSocket 连接已关闭，代码: \(closeCode.rawValue)，原因: \(reasonStr)")
        connectionState = .disconnected
        DispatchQueue.main.async {
            self.onConnectionStateChange?(.disconnected)
        }
    }
}
