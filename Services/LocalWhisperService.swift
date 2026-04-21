// LocalWhisperService.swift
// VoiceBabel - macOS 菜单栏语音转文字工具
//
// WhisperKit 本地转写服务 —— 基于 CoreML 的离线语音识别。
//
// 职责：
//   1. 模型管理：首次自动下载 openai_whisper-large-v3 (~626MB)，后续从本地缓存加载
//   2. 语音转录：接收 Float32 PCM 采样（16kHz），通过 WhisperKit 进行本地推理
//   3. 识别率优化：温度回退策略（0.0→0.2→0.4...，最多 5 次）、幻觉检测（压缩比 2.4）、VAD 分块
//   4. 时长感知超时：基于音频时长推算内部超时（10×分钟，夹在 Min/Max 之间），超时抛出
//
// 转录参数说明：
//   - temperature: 0.0 起步（贪婪解码），逐步升温增加多样性
//   - compressionRatioThreshold: 2.4（高于此值视为幻觉，触发重试）
//   - noSpeechThreshold: 0.3（比默认 0.6 更宽容，避免误判正常语音）
//   - chunkingStrategy: .vad（基于语音活动检测切分，避免长段音频注意力分散）
//
// 依赖：
//   - WhisperKit：CoreML 本地 Whisper 推理引擎
//   - EngineeringOptions：localWhisperModel（模型名称）、apiProcessingTimeoutMin/Max、sampleRate
//   - LocaleManager.whisperCode(for:)：用户语言码 → WhisperKit 语言码
//
// 架构角色：
//   由 AppDelegate 创建并预加载模型，由 TranscriptionManager 在每次转录时传入
//   language 和 audioDuration。language 不再作为状态存储 —— 调用方决定。
//   文本后处理（标签过滤、繁简转换）由 TranscriptionManager 通过 TextPostProcessor 统一处理。
//
// 限制：
//   仅支持转录，不支持翻译（翻译模式自动使用 CloudOpenAIService 或 LocalAppleTranslationService）。

import Combine
import Foundation
import WhisperKit

final class LocalWhisperService: ObservableObject {

    // MARK: - 状态

    /// WhisperKit 实例
    private var whisperKit: WhisperKit?

    /// 模型是否已加载
    private(set) var isModelLoaded: Bool = false

    /// 模型是否正在加载/下载中
    private(set) var isModelLoading: Bool = false

    /// Observable mirror of `isReady()` state. AppDelegate subscribes to this via
    /// Combine to trigger engine-availability re-probes. Subscribers must not write.
    @Published private(set) var isReadyState: Bool = false

    // MARK: - 错误类型

    enum LocalWhisperError: Error, LocalizedError {
        case modelNotLoaded
        case noAudioData
        case timedOut(TimeInterval)
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return String(localized: "WhisperKit model not loaded yet, please wait")
            case .noAudioData:
                return String(localized: "No audio data available for transcription")
            case .timedOut(let seconds):
                return String(localized: "Local transcription timed out after \(String(format: "%.0f", seconds))s, try shorter recordings")
            case .transcriptionFailed(let reason):
                return String(localized: "Local transcription failed: \(reason)")
            }
        }
    }

    // MARK: - 初始化

    /// 初始化本地 Whisper 服务
    ///
    /// 无状态构造 —— 语言参数随每次 `transcribe` 调用传入，由 TranscriptionManager 解析。
    init() {}

    // MARK: - 公共方法

    /// 异步加载模型
    /// 首次调用会自动下载模型文件（~626MB），后续从本地缓存加载。
    /// 建议在 AppDelegate 启动时调用以预热模型。
    func loadModel() async throws {
        await MainActor.run { self.isModelLoading = true }
        Log.i(LocaleManager.shared.logLocalized("LocalWhisper: loading model..."))

        do {
            let config = WhisperKitConfig(model: EngineeringOptions.localWhisperModel, download: true)
            let kit = try await WhisperKit(config)

            await MainActor.run {
                self.whisperKit = kit
                self.isModelLoaded = true
                self.isModelLoading = false
                self.isReadyState = true
            }
            Log.i(LocaleManager.shared.logLocalized("LocalWhisper: model loaded"))
        } catch {
            await MainActor.run { self.isModelLoading = false }
            Log.e(LocaleManager.shared.logLocalized("LocalWhisper: model loading failed:") + " \(error.localizedDescription)")
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
    /// 内部基于 `audioDuration` 计算超时（公式：`clamp(minutes * 10, Min, Max)`），
    /// 超时触发 `LocalWhisperError.timedOut` 抛出。返回未经后处理的原始文本 ——
    /// 标签过滤 / 繁简转换由调用方（TranscriptionManager）通过 TextPostProcessor 统一完成。
    ///
    /// - Parameters:
    ///   - samples: Float32 PCM 采样数据（16kHz 单声道）
    ///   - language: VoiceBabel 语言码（"zh" / "en" / ""）；空串触发自动检测
    ///   - audioDuration: 音频时长（秒），用于推算超时
    /// - Returns: 原始转录文本（未过滤标签、未做繁简转换、未 trim）
    func transcribe(samples: [Float], language: String, audioDuration: TimeInterval) async throws -> String {
        guard let whisperKit = whisperKit, isModelLoaded else {
            Log.e(LocaleManager.shared.logLocalized("LocalWhisper: transcription rejected, model not loaded"))
            throw LocalWhisperError.modelNotLoaded
        }

        guard !samples.isEmpty else {
            Log.w(LocaleManager.shared.logLocalized("LocalWhisper: transcription rejected, no audio data"))
            throw LocalWhisperError.noAudioData
        }

        let lm = LocaleManager.shared

        // 基于音频时长推算超时：每分钟 10s，夹在 [Min, Max] 区间
        let minutes = audioDuration / 60.0
        let timeout = min(
            max(minutes * 10, EngineeringOptions.apiProcessingTimeoutMin),
            EngineeringOptions.apiProcessingTimeoutMax
        )
        Log.i(lm.logLocalized("LocalWhisper: starting transcription, sample count:") + " \(samples.count), " + lm.logLocalized("duration:") + " \(String(format: "%.1f", audioDuration))s, " + lm.logLocalized("local processing timeout") + " \(String(format: "%.0f", timeout))s")

        // 配置解码选项
        var options = DecodingOptions()
        options.task = .transcribe
        if !language.isEmpty {
            options.language = LocaleManager.whisperCode(for: language)
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

        // 两个 prefill 开关互相正交，都保留：
        //   usePrefillPrompt —— 强制写入 task/language 前缀 token（影响解码起点）
        //   usePrefillCache  —— 从 prefill_data.mlmodel 预填 KV cache（纯性能优化，仅在 usePrefillPrompt=true 时生效）
        // 参考：WhisperKit/Sources/WhisperKit/Core/Configurations.swift:109-110
        options.usePrefillPrompt = true
        options.usePrefillCache = true

        // 抑制空白 token，减少无意义输出
        options.suppressBlank = true

        // 使用 VAD 分块策略：基于语音活动检测切分音频
        // 避免将长段音频一次性送入模型导致注意力分散
        options.chunkingStrategy = .vad

        // 在 TaskGroup 中竞速：WhisperKit 推理 vs 定时器。先到者胜出，另一侧取消。
        do {
            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
                    // 仅合并分段结果，不做任何后处理（调用方负责 trim/标签过滤/繁简转换）
                    return results.map { $0.text }.joined(separator: " ")
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw LocalWhisperError.timedOut(timeout)
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            if text.isEmpty {
                Log.i(lm.logLocalized("LocalWhisper: transcription result is empty"))
            } else {
                Log.i(lm.logLocalized("LocalWhisper: transcription complete:") + " \(text)")
            }
            return text
        } catch let error as LocalWhisperError {
            // 超时 / 已定义的本服务错误原样抛出，便于调用方区分
            if case .timedOut(let seconds) = error {
                Log.e(lm.logLocalized("LocalWhisper: transcription") + " " + lm.logLocalized("timed out") + " (\(String(format: "%.0f", seconds))s)")
            }
            throw error
        } catch {
            // WhisperKit / 底层错误包装成 transcriptionFailed，保留原始描述
            Log.e(lm.logLocalized("LocalWhisper: transcription") + " " + lm.logLocalized("failed:") + " \(error)")
            throw LocalWhisperError.transcriptionFailed(error.localizedDescription)
        }
    }
}
