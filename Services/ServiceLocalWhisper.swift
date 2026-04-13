// ServiceLocalWhisper.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// WhisperKit 本地转写服务 —— 基于 CoreML 的离线语音识别。
//
// 职责：
//   1. 模型管理：首次自动下载 openai_whisper-large-v3 (~626MB)，后续从本地缓存加载
//   2. 语音转录：接收 Float32 PCM 采样（16kHz），通过 WhisperKit 进行本地推理
//   3. 识别率优化：温度回退策略（0.0→0.2→0.4...，最多 5 次）、幻觉检测（压缩比 2.4）、VAD 分块
//   4. 后处理管线：特殊标签过滤（[MUSIC]/[BLANK_AUDIO]）→ 繁简转换（可选）
//
// 转录参数说明：
//   - temperature: 0.0 起步（贪婪解码），逐步升温增加多样性
//   - compressionRatioThreshold: 2.4（高于此值视为幻觉，触发重试）
//   - noSpeechThreshold: 0.3（比默认 0.6 更宽容，避免误判正常语音）
//   - chunkingStrategy: .vad（基于语音活动检测切分，避免长段音频注意力分散）
//
// 依赖：
//   - WhisperKit：CoreML 本地 Whisper 推理引擎
//   - EngineeringOptions：localWhisperModel（模型名称）、enableTraditionalToSimplified、enableTagFiltering
//
// 架构角色：
//   由 AppDelegate 创建并预加载模型，由 RecordingController 在 local 模式下调用。
//   也作为 Cloud API 网络回退的后备方案。
//
// 限制：
//   仅支持转录，不支持翻译（翻译模式自动使用 ServiceCloudOpenAI）。

import Foundation
import WhisperKit

class ServiceLocalWhisper {

    // MARK: - 状态

    /// WhisperKit 实例
    private var whisperKit: WhisperKit?

    /// 模型是否已加载
    private(set) var isModelLoaded: Bool = false

    /// 模型是否正在加载/下载中
    private(set) var isModelLoading: Bool = false

    /// 语言参数："zh", "en", "" (自动检测)
    private let language: String

    // MARK: - 错误类型

    enum LocalWhisperError: Error, LocalizedError {
        case modelNotLoaded
        case noAudioData
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "WhisperKit 模型尚未加载，请稍候"
            case .noAudioData:
                return "没有音频数据可供转录"
            case .transcriptionFailed(let reason):
                return "本地转录失败: \(reason)"
            }
        }
    }

    // MARK: - 初始化

    /// 初始化本地 Whisper 服务
    /// - Parameter language: 语言参数，"zh"/"en"/""(自动检测)
    init(language: String) {
        self.language = language
    }

    // MARK: - 公共方法

    /// 异步加载模型
    /// 首次调用会自动下载模型文件（~626MB），后续从本地缓存加载。
    /// 建议在 AppDelegate 启动时调用以预热模型。
    func loadModel() async throws {
        isModelLoading = true
        Log.i("LocalWhisper: 正在加载模型...")

        do {
            let config = WhisperKitConfig(model: EngineeringOptions.localWhisperModel, download: true)
            let kit = try await WhisperKit(config)

            self.whisperKit = kit
            self.isModelLoaded = true
            self.isModelLoading = false
            Log.i("LocalWhisper: 模型加载完成")
        } catch {
            self.isModelLoading = false
            throw error
        }
    }

    /// 检查模型是否已就绪
    func isReady() -> Bool {
        return isModelLoaded && whisperKit != nil
    }

    /// 转录音频采样数据
    ///
    /// 接收 Float32 PCM 采样数据（16kHz 单声道），使用 WhisperKit 进行本地转录。
    /// 录音停止后由 RecordingController 调用。
    ///
    /// - Parameter samples: Float32 PCM 采样数据（16kHz 单声道）
    /// - Returns: 转录文本
    func transcribe(samples: [Float]) async throws -> String {
        guard let whisperKit = whisperKit, isModelLoaded else {
            throw LocalWhisperError.modelNotLoaded
        }

        guard !samples.isEmpty else {
            throw LocalWhisperError.noAudioData
        }

        Log.i("LocalWhisper: 开始转录，采样点数: \(samples.count)，时长: \(String(format: "%.1f", Double(samples.count) / 16000.0))秒")

        // 配置解码选项
        var options = DecodingOptions()
        options.task = .transcribe
        if !language.isEmpty {
            options.language = language
        } else {
            // 语言未指定时启用自动检测（WhisperKit 默认英文，需显式开启检测）
            options.detectLanguage = true
        }

        // === 识别率优化参数 ===

        // 温度回退：初始温度 0（贪婪解码，最确定的结果）
        // 如果压缩比或 logProb 不合格，逐步升温重试，增加多样性
        options.temperature = 0.0
        options.temperatureIncrementOnFallback = 0.2
        options.temperatureFallbackCount = 5

        // 幻觉检测：压缩比过高说明模型在重复自己（典型幻觉特征）
        options.compressionRatioThreshold = 2.4
        // 低置信度检测：平均 logProb 低于阈值说明模型不确定，触发温度回退
        options.logProbThreshold = -1.0
        options.firstTokenLogProbThreshold = -1.5

        // 无语音检测：0.3 比默认的 0.6 更宽容，避免正常语音被误判为噪音
        // 但不能太低，否则会产生幻觉（对着静音也输出文字）
        options.noSpeechThreshold = 0.3

        // 启用前缀提示和缓存，帮助模型更好地理解语言上下文
        options.usePrefillPrompt = true
        options.usePrefillCache = true

        // 抑制空白 token，减少无意义输出
        options.suppressBlank = true

        // 使用 VAD 分块策略：基于语音活动检测切分音频
        // 避免将长段音频一次性送入模型导致注意力分散
        options.chunkingStrategy = .vad

        // 使用 WhisperKit 转录
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)

        // 合并所有转录结果
        var text = results.map { $0.text }
            .joined(separator: " ")

        // 过滤掉特殊标签（如 [MUSIC]、[BLANK_AUDIO] 等）
        if EngineeringOptions.enableTagFiltering {
            text = text.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 繁体中文 → 简体中文转换
        if EngineeringOptions.enableTraditionalToSimplified {
            let mutableText = NSMutableString(string: text)
            CFStringTransform(mutableText, nil, "Traditional-Simplified" as CFString, false)
            text = mutableText as String
        }

        if text.isEmpty {
            Log.i("LocalWhisper: 转录结果为空")
        } else {
            Log.i("LocalWhisper: 转录完成: \(text)")
        }

        return text
    }
}
