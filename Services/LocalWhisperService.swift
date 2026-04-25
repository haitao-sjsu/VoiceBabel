// LocalWhisperService.swift
// VoiceBabel - macOS 菜单栏语音转文字工具
//
// WhisperKit 本地转写服务 —— 基于 CoreML 的离线语音识别。
//
// 职责：
//   1. 模型管理：首次自动下载 openai_whisper-large-v3 (~626MB)，后续从本地缓存加载
//   2. 语音转录：接收 Float32 PCM 采样（16kHz），通过 WhisperKit 进行本地推理
//   3. 识别率优化：温度回退策略（0.0→0.2→0.4...，最多 5 次）、幻觉检测（压缩比 2.4）、VAD 分块
//   4. 状态机：暴露 LocalWhisperState（notDownloaded / downloading / loading / loaded /
//      warming / ready / failed）。AppDelegate 通过 Combine 订阅 `$state` 触发
//      EngineAvailabilityProbe 重算；UI 通过 `statusDescription` 展示具体阶段。
//   5. 预热：模型加载完成后自动跑一次 1 秒静音转录把 ANE 真正预热（首次可能 60s+），
//      避免用户首次实际录音时遭遇冷启动卡顿。
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

// MARK: - 状态机

/// LocalWhisperService 当前生命周期状态。
///
/// 设计原则：所有从外部观察到的"local 引擎可用性"都来源于此枚举。EngineAvailabilityProbe
/// 把非 .ready 一律视为不可用并把 statusDescription 透传给 UI。状态变迁路径：
///
///   notDownloaded → downloading → loading → loaded → warming → ready
///                       │            │         │
///                       ▼            ▼         ▼
///                  failed(.download)/load/warmup
///
///   ready ── 运行时异常 ──▶ failed(.runtime)
///
/// 备注：`.downloaded`（下载完成但未加载）状态被刻意省略 —— WhisperKit 不暴露下载完成
/// 回调，从外部观察到 `.downloading → .loading` 的瞬时切换没有意义。
enum LocalWhisperState: Equatable {
    case notDownloaded
    case downloading
    case loading
    case loaded
    case warming
    case ready
    case failed(stage: FailureStage, reason: String)
}

/// 失败发生的阶段，用于 UI 文案区分（"Download failed" vs "Warm-up failed" 等）
/// 和后续判断恢复策略（运行时异常 vs 启动阶段异常）。
enum FailureStage: Equatable {
    case download
    case load
    case warmup
    case runtime
}

final class LocalWhisperService: ObservableObject {

    // MARK: - 状态

    /// WhisperKit 实例
    private var whisperKit: WhisperKit?

    /// 当前生命周期状态。AppDelegate 通过 Combine 订阅触发 EngineAvailabilityProbe 重算；
    /// UI 通过 `statusDescription` 把状态映射成用户可读字符串。
    @Published private(set) var state: LocalWhisperState = .notDownloaded

    /// 简单可用性查询：state == .ready 时为 true。
    var isReady: Bool { state == .ready }

    /// 把当前状态映射成已本地化的人类可读字符串，供 UI 行的 subtitle 展示。
    /// 失败状态会拼接具体 reason（来自底层 error.localizedDescription）。
    var statusDescription: String {
        let lm = LocaleManager.shared
        switch state {
        case .notDownloaded:
            return lm.localized("localwhisper.state.notDownloaded")
        case .downloading:
            return lm.localized("localwhisper.state.downloading")
        case .loading:
            return lm.localized("localwhisper.state.loading")
        case .loaded:
            return lm.localized("localwhisper.state.loaded")
        case .warming:
            return lm.localized("localwhisper.state.warming")
        case .ready:
            return lm.localized("localwhisper.state.ready")
        case .failed(let stage, let reason):
            let key: String
            switch stage {
            case .download: key = "localwhisper.state.failed.download"
            case .load:     key = "localwhisper.state.failed.load"
            case .warmup:   key = "localwhisper.state.failed.warmup"
            case .runtime:  key = "localwhisper.state.failed.runtime"
            }
            return String(format: lm.localized(key), reason)
        }
    }

    // MARK: - 错误类型

    enum LocalWhisperError: Error, LocalizedError {
        case modelNotLoaded
        case noAudioData
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return String(localized: "WhisperKit model not loaded yet, please wait")
            case .noAudioData:
                return String(localized: "No audio data available for transcription")
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

    /// 异步加载模型 + 预热
    /// 首次调用会自动下载模型文件（~626MB），后续从本地缓存加载。
    /// 加载成功后立即跑一次极短转录预热 ANE（首次冷启动可能 60s+）。
    /// 建议在 AppDelegate 启动时调用。
    func loadModel() async throws {
        let lm = LocaleManager.shared

        // 启动阶段先嗅探磁盘：模型目录已存在 → 走 .loading；否则 → .downloading。
        // WhisperKit 没有暴露下载进度回调，只能在 init 之前通过这个一次性快照粗分两个阶段。
        let modelName = EngineeringOptions.localWhisperModel
        let modelDir = NSHomeDirectory()
            + "/Documents/huggingface/models/argmaxinc/whisperkit-coreml/"
            + modelName
        let alreadyDownloaded = FileManager.default.fileExists(atPath: modelDir)

        await MainActor.run {
            self.state = alreadyDownloaded ? .loading : .downloading
        }
        Log.i(lm.logLocalized("LocalWhisper: loading model..."))

        do {
            let config = WhisperKitConfig(model: modelName, download: true)
            let kit = try await WhisperKit(config)

            await MainActor.run {
                self.whisperKit = kit
                self.state = .loaded
            }
            Log.i(lm.logLocalized("LocalWhisper: model loaded"))
        } catch {
            // 失败 stage 取决于"开始时是否已经在磁盘上"：未下载 → download 失败；已下载 → load 失败。
            let stage: FailureStage = alreadyDownloaded ? .load : .download
            await MainActor.run {
                self.state = .failed(stage: stage, reason: error.localizedDescription)
            }
            Log.e(lm.logLocalized("LocalWhisper: model loading failed:") + " \(error.localizedDescription)")
            throw error
        }

        // 加载成功 → 立即预热。预热失败不向上抛 —— 状态已置 .failed(.warmup, ...)，
        // 探针会自动把 local 标为不可用。
        await warmup()
    }

    /// 转录音频采样数据
    ///
    /// 接收 Float32 PCM 采样数据（16kHz 单声道），使用 WhisperKit 进行本地转录。
    /// 返回未经后处理的原始文本 —— 标签过滤 / 繁简转换由调用方（TranscriptionManager）
    /// 通过 TextPostProcessor 统一完成。
    ///
    /// - Parameters:
    ///   - samples: Float32 PCM 采样数据（16kHz 单声道）
    ///   - language: VoiceBabel 语言码（"zh" / "en" / ""）；空串触发自动检测
    ///   - audioDuration: 音频时长（秒），仅用于日志诊断
    /// - Returns: 原始转录文本（未过滤标签、未做繁简转换、未 trim）
    func transcribe(samples: [Float], language: String, audioDuration: TimeInterval) async throws -> String {
        // 状态守卫：只有 .ready 才允许真实业务转录调用。注意 warmup() 内部直接用 whisperKit?.transcribe(...)
        // 不会走到这里，所以 warming 阶段不会被这条 guard 阻塞。
        guard state == .ready, let whisperKit = whisperKit else {
            Log.e(LocaleManager.shared.logLocalized("LocalWhisper: transcription rejected, model not loaded"))
            throw LocalWhisperError.modelNotLoaded
        }

        guard !samples.isEmpty else {
            Log.w(LocaleManager.shared.logLocalized("LocalWhisper: transcription rejected, no audio data"))
            throw LocalWhisperError.noAudioData
        }

        let lm = LocaleManager.shared
        Log.i(lm.logLocalized("LocalWhisper: starting transcription, sample count:") + " \(samples.count), " + lm.logLocalized("duration:") + " \(String(format: "%.1f", audioDuration))s")

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

        // 直接 await，不设硬超时。
        //
        // 历史上这里曾用 withThrowingTaskGroup 跑"推理 vs 定时器"竞速以实现
        // "N 秒还没出结果就抛 timedOut"。看似稳妥，实际上有两个问题让它弊大于利：
        //
        // 1) 取消的是 Swift Task，不是底层推理。Swift 的取消是协作式（cooperative）—
        //    只是举旗子说"该停了"，被取消方必须自觉检查。WhisperKit 内部是 CoreML / ANE
        //    的同步阻塞调用，根本不查这面旗子。所以"超时取消"并不能真正释放算力，
        //    只是把已经在跑的推理结果丢掉。
        //
        // 2) 临界区会丢正确结果。当推理刚好接近超时阈值才完成时，定时器和推理"几乎
        //    同时就绪"，调度器按 FIFO 派单 → 已经过期等候的定时器先抛 timedOut →
        //    group.next() 拿到错误返回 → 已经跑出来的正确转录文本被静默丢弃 →
        //    Manager 无谓 fallback 到 cloud。冷启动场景下这个 bug 表现得最明显
        //    （一次成功的 60 秒推理被报告为"5 秒超时"）。
        //
        // 取舍：移除自动超时，改用两层兜底。
        //   - 用户层：Bug A 修复后，按 ESC 立即取消 pipeline 任务，AppController
        //     在写入文本前用 Task.isCancelled 守卫丢弃任何后到结果。这是最可靠的
        //     "停下"渠道。
        //   - 系统层：WhisperKit 真抛异常时（模型损坏 / ANE 故障等），下方 catch
        //     标脏 state 为 .failed(.runtime, ...)，EngineAvailabilityProbe 立即
        //     把 local 剔出有效列表，后续调用直接走 cloud，无需再依赖超时检测。
        //
        // 详见 .dev-docs-private/.claude-tech-research/33_local_whisper_timeout_race.md。
        do {
            let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
            // 仅合并分段结果，不做任何后处理（调用方负责 trim/标签过滤/繁简转换）
            let text = results.map { $0.text }.joined(separator: " ")

            if text.isEmpty {
                Log.i(lm.logLocalized("LocalWhisper: transcription result is empty"))
            } else {
                Log.i(lm.logLocalized("LocalWhisper: transcription complete:") + " \(text)")
            }
            return text
        } catch is CancellationError {
            // 用户按 ESC 取消时，AppController 会 cancel 持有的 pipeline Task，
            // 取消旗子最终传到这里。原样抛出，由 TranscriptionManager 的循环顶部
            // try Task.checkCancellation() 短路掉 fallback 链，AppController 的
            // `catch is CancellationError` 安静吞掉。**不要**在这里翻 state 为 .failed
            // —— 取消是良性事件，不代表 WhisperKit 损坏。
            throw CancellationError()
        } catch {
            // WhisperKit / 底层真实异常 → 标脏整个服务。
            // 后续 EngineAvailabilityProbe 看到非 ready 状态，会把 local 从有效列表中剔除，
            // AppController 自动 fallback 到 cloud。直到 app 重启前不会再尝试 local。
            await MainActor.run {
                self.state = .failed(stage: .runtime, reason: error.localizedDescription)
            }
            Log.e(lm.logLocalized("LocalWhisper: transcription") + " " + lm.logLocalized("failed:") + " \(error)")
            throw LocalWhisperError.transcriptionFailed(error.localizedDescription)
        }
    }

    // MARK: - 私有方法

    /// 模型加载完成后立即跑一次 1 秒静音转录，把 CoreML / ANE 真正预热。
    /// 首次预热可能耗时 60s+（ANE 编译），但发生在启动阶段而非用户首次实际使用时。
    /// 失败不抛出 —— 状态置为 .failed(.warmup)，探针自然把 local 标为不可用。
    private func warmup() async {
        let lm = LocaleManager.shared
        await MainActor.run { self.state = .warming }
        Log.i(lm.logLocalized("LocalWhisper: warmup started"))
        do {
            let silentSamples = [Float](repeating: 0.0, count: 16000)  // 1s @ 16kHz
            var options = DecodingOptions()
            options.task = .transcribe
            options.language = "en"      // 显式指定语言，跳过 detectLanguage 开销
            options.usePrefillPrompt = true
            options.usePrefillCache = true
            _ = try await whisperKit?.transcribe(audioArray: silentSamples, decodeOptions: options)
            await MainActor.run { self.state = .ready }
            Log.i(lm.logLocalized("LocalWhisper: warmup complete"))
        } catch {
            await MainActor.run {
                self.state = .failed(stage: .warmup, reason: error.localizedDescription)
            }
            Log.e(lm.logLocalized("LocalWhisper: warmup failed:") + " \(error)")
        }
    }
}
