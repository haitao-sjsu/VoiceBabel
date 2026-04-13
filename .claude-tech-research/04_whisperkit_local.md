# WhisperKit 本地转录研究报告

## 摘要

WhisperKit 是 Argmax 开发的开源 Swift 框架，通过 CoreML 在 Apple Silicon 上本地运行 OpenAI Whisper 模型。截至 2025 年 3 月最新版本为 v0.17.0，已扩展为包含语音转文字 (WhisperKit)、说话人分离 (SpeakerKit)、文字转语音 (TTSKit) 的多功能套件。项目当前使用的 `openai_whisper-large-v3-v20240930_626MB` 是一个合理的选择，在准确率和资源占用间取得了良好平衡，但建议考虑切换到同系列的 turbo 变体 (`_turbo_632MB`) 以获得更低的流式延迟。Apple 在 WWDC 2025 推出的 SpeechAnalyzer 是未来需要关注的竞争方案，速度更快但准确率和多语言支持弱于 WhisperKit。

## 详细报告

### 1. WhisperKit 框架概述

**基本信息：**
- 开发者：Argmax Inc.
- 许可：MIT 开源
- 语言：Swift
- 最新版本：v0.17.0 (2025-03-13)
- 仓库：https://github.com/argmaxinc/WhisperKit
- 系统要求：macOS 14.0+ (Sonoma)，Apple Silicon (M1/M2/M3/M4)

**版本历史（近期）：**

| 版本 | 日期 | 关键更新 |
|------|------|---------|
| v0.17.0 | 2025-03-13 | SpeakerKit：Pyannote 说话人分离；RTTM 输出；CLI diarize 子命令 |
| v0.16.0 | 2025-03-03 | TTSKit：基于 Qwen3-TTS 的设备端文字转语音；实时自适应流式输出 |
| v0.15.0 | 2024-11-07 | 升级 swift-transformers 依赖；TranscriptionResult 升级为 open class |
| v0.14.1 | 2024-10-17 | Swift 6 并发改进；公共结构体添加 Sendable 一致性 |
| v0.14.0 | 2024-09-20 | WhisperKit Local Server：OpenAI 兼容 HTTP 端点；SSE 流式输出 |
| v0.13.1 | 2024-07-31 | 修复 tokenizer 加载和 logit 过滤器问题 |
| v0.13.0 | 2024-06-13 | 异步 VAD 支持和分段发现回调 |

**核心架构：**
WhisperKit 将 Whisper PyTorch 模型转换为 CoreML 格式，利用 Apple Neural Engine (ANE) 加速推理。框架包含完整的音频处理管线：音频预处理 -> 特征提取 -> 编码器 -> 解码器 -> 后处理。

### 2. 可用模型对比

WhisperKit 通过 Hugging Face Hub (`argmaxinc/whisperkit-coreml`) 分发模型，共 27 个变体：

**按系列分类：**

| 模型系列 | 变体 | 参数量 | 磁盘大小 | 适用场景 |
|---------|------|--------|---------|---------|
| **openai_whisper-tiny** | tiny, tiny.en | 39M | ~75MB | 极低延迟、低资源设备 |
| **openai_whisper-base** | base, base.en | 74M | ~140MB | 快速原型、英文简单场景 |
| **openai_whisper-small** | small, small.en, 216/217MB 压缩版 | 244M | ~460MB / 216MB | 移动设备、中等准确率 |
| **openai_whisper-medium** | medium, medium.en | 769M | ~1.5GB | 高准确率、桌面应用 |
| **openai_whisper-large-v2** | 原版, 949MB压缩, turbo, turbo_955MB | 1.5B | ~3GB / 949MB | 最高准确率（v2 基线） |
| **openai_whisper-large-v3** | 原版, 947MB压缩, turbo, turbo_954MB | 1.5B | ~3GB / 947MB | 最高准确率（v3 改进多语言） |
| **openai_whisper-large-v3-v20240930** | 原版, 547MB, **626MB**, turbo, **turbo_632MB** | 1B (turbo) | 547-632MB | **项目当前使用**，压缩+turbo优化 |
| **distil-whisper_distil-large-v3** | 原版, 594MB压缩, turbo, turbo_600MB | ~756M | ~1.5GB / 594MB | 蒸馏模型，速度快 |

**项目当前模型详情：**
- 模型标识：`openai_whisper-large-v3-v20240930_626MB`
- 这是 large-v3-turbo (v20240930) 的量化压缩版本
- 编码器保持 large-v3 的完整能力，解码器仅 4 层（从 32 层精简）
- 626MB 是通过模型压缩从原始 ~1.6GB 缩减而来

**关键性能指标（来自 Argmax 论文和社区基准）：**

| 模型 | 大小 | WER (LibriSpeech) | QoI | 备注 |
|------|------|-------------------|-----|------|
| large-v3_turbo (原版) | ~3.1GB | 2.41% | 99.8% | 未压缩基线 |
| large-v3_turbo_1307MB | 1.3GB | 2.6% | 97.7% | 中度压缩 |
| large-v3_turbo_1049MB | 1.0GB | 4.81% | 91.0% | 重度压缩 |
| large-v3-v20240930_626MB | 626MB | ~3-4% (估计) | ~95% (估计) | **项目当前使用** |

### 3. 核心 API 与配置参数

#### 3.1 WhisperKitConfig（初始化配置）

```swift
let config = WhisperKitConfig(
    model: "openai_whisper-large-v3-v20240930_626MB",  // 模型标识
    download: true,          // 自动下载缺失模型
    computeOptions: nil,     // 计算设备选项（ANE/GPU/CPU）
    voiceActivityDetector: nil,  // VAD 配置
    verbose: true,           // 日志详细程度
    logLevel: .info,         // 日志级别
    prewarm: nil,            // 模型预热（specialization）
    load: nil                // 加载可用模型
)
```

#### 3.2 DecodingOptions（解码配置）— 项目当前使用的参数

```swift
var options = DecodingOptions()

// --- 任务与语言 ---
options.task = .transcribe              // 转录模式
options.language = "zh"                 // 或 "en"，或 nil 自动检测
options.detectLanguage = true           // 语言未指定时启用

// --- 温度回退策略 ---
options.temperature = 0.0              // 初始温度（贪婪解码）[默认: 0.0]
options.temperatureIncrementOnFallback = 0.2  // 回退增量 [默认: 0.2]
options.temperatureFallbackCount = 5   // 最大回退次数 [默认: 5]

// --- 质量阈值 ---
options.compressionRatioThreshold = 2.4      // 压缩比阈值 [默认: 2.4]
options.logProbThreshold = -1.0              // 平均 logProb 阈值 [默认: -1.0]
options.firstTokenLogProbThreshold = -1.5    // 首 token logProb 阈值 [默认: -1.5]
options.noSpeechThreshold = 0.3              // 无语音阈值 [项目: 0.3, 默认: 0.6]

// --- 前缀与缓存 ---
options.usePrefillPrompt = true        // 预填充提示 [默认: true]
options.usePrefillCache = true         // 预填充 KV 缓存 [默认: true]

// --- 输出控制 ---
options.suppressBlank = true           // 抑制空白 token [默认: true]

// --- 分块策略 ---
options.chunkingStrategy = .vad        // VAD 分块 [项目使用]

// --- 并发 ---
options.concurrentWorkerCount = 16     // macOS 默认值
```

#### 3.3 其他可用但项目未使用的参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `topK` | Int | 5 | 采样时的候选数量 |
| `sampleLength` | Int | - | 最大 token 采样长度 |
| `wordTimestamps` | Bool | false | 词级时间戳 |
| `skipSpecialTokens` | Bool | false | 跳过特殊 token |
| `withoutTimestamps` | Bool | false | 不输出时间戳 |
| `clipTimestamps` | [Float] | [] | 时间裁剪点 |
| `promptTokens` | [Int]? | nil | 条件提示 token |
| `prefixTokens` | [Int]? | nil | 解码器前缀 token |
| `supressTokens` | [Int] | [] | 需抑制的 token ID 列表 |

### 4. 幻觉检测与过滤

Whisper 模型的幻觉问题是已知的核心挑战，表现为：
- **重复循环**：模型反复输出相同的短语
- **静音幻觉**：对无语音片段生成虚假文本
- **语言混淆**：多语言场景下错误切换语言

**WhisperKit 的多层防御机制：**

#### 4.1 压缩比检测 (compressionRatioThreshold = 2.4)
- 原理：使用 zlib 压缩生成的文本，计算压缩比
- 重复文本的压缩比远高于正常文本
- 超过阈值 2.4 时触发温度回退重新解码
- 这是对抗重复循环幻觉的主要手段

#### 4.2 置信度检测 (logProbThreshold = -1.0)
- 原理：计算所有生成 token 的平均 log 概率
- 低于 -1.0 说明模型整体不确定，触发回退
- 首 token 阈值 -1.5 额外检查开头是否就走偏了

#### 4.3 无语音检测 (noSpeechThreshold)
- 默认 0.6，项目设为 0.3（更宽容）
- 原理：模型输出的 no_speech 概率超过阈值则判定为静音
- 项目设为 0.3 的理由：避免将正常语音误判为噪音（特别是中文低音量说话）
- 风险：太低可能导致静音段产生幻觉

#### 4.4 温度回退策略
- 初始温度 0.0（贪婪解码，最确定的结果）
- 如果质量检测不过关，温度 += 0.2 重试
- 最多重试 5 次（温度最高 1.0）
- 升温增加解码多样性，有机会跳出重复循环

#### 4.5 项目额外的后处理过滤
- 标签过滤：正则移除 `[MUSIC]`、`[BLANK_AUDIO]` 等特殊标签
- 空白抑制：`suppressBlank = true` 减少无意义输出

### 5. Apple Silicon 性能表现

#### 5.1 Neural Engine 优化

WhisperKit 核心优势在于利用 Apple Neural Engine (ANE) 加速推理，ANE 是 Apple Silicon 中专门用于机器学习的硬件单元。

**M3 Max ANE 关键指标（来自 Argmax 论文）：**
- 音频编码器延迟：218ms（d750 变体）
- 文本解码器延迟：4.6ms（通过 Stateful Models 优化，比旧方案降低 45%）
- 单次前向传播能耗：0.3W（降低 75%）

#### 5.2 各芯片性能对比

**基于 Medium 模型处理 10 分钟音频的基准测试：**

| 芯片 | 处理时间 | 实时因子 (RTF) | 备注 |
|------|---------|---------------|------|
| M1 | ~3 分钟 | 0.3x | 基线，完全可用 |
| M1 Pro | ~2 分钟 | 0.2x | Pro 核心数更多 |
| M2 | ~2.5 分钟 | 0.25x | ANE 改进 |
| M3 Pro | ~1.5 分钟 | 0.15x | 显著提升 |
| M3 Max | ~1 分钟 | 0.1x | ANE + GPU 双路加速 |
| M4 | ~1.2 分钟 | 0.12x | 新架构效率更高 |
| M4 Pro | ~50 秒 | 0.08x | 当前最快消费级 |

**Large-v3-turbo 专项基准（M2 Ultra）：**
- ANE 模式：42x 实时速率
- GPU+ANE 混合模式：72x 实时速率

#### 5.3 WhisperKit 在线延迟（流式转录）

来自 Argmax 论文的实时 ASR 基准：
- 假设文本 (hypothesis) 平均延迟：0.45 秒/词
- 确认文本 (confirmed) 平均延迟：~1.7 秒
- 对比 Deepgram nova-3 云端：0.83 秒（WhisperKit 本地更快）

### 6. 与其他本地方案对比

#### 6.1 Apple SpeechAnalyzer (macOS 26 Tahoe, WWDC 2025)

| 维度 | WhisperKit | Apple SpeechAnalyzer |
|------|-----------|---------------------|
| 可用性 | 现在可用 (macOS 14+) | macOS 26+ (2025 秋季) |
| 速度 | 快（ANE 优化） | 更快（55% faster than WhisperKit large-v3-turbo） |
| 准确率 (earnings22) | 12.8-15.2% WER | 14.0% WER |
| 语言支持 | 100+ 语言 | 仅 10 语言 |
| 说话人分离 | 支持 (SpeakerKit) | 不支持 |
| 自定义词汇 | 支持（匹配顶级云端 API） | 不支持 |
| 语言检测 | 支持 | 不支持 |
| 开源 | 是 (MIT) | 否 |
| 模型更新 | 社区/Argmax 持续更新 | Apple 系统更新 |

**评估：** Apple SpeechAnalyzer 速度更快、无需额外下载模型，但在多语言支持（仅 10 种语言，不确定是否包含中文）和高级功能上远不如 WhisperKit。对于中英混杂识别场景，WhisperKit 仍是更好的选择。

#### 6.2 mlx-whisper

| 维度 | WhisperKit | mlx-whisper |
|------|-----------|-------------|
| 框架 | CoreML + ANE | MLX (Apple ML 框架) |
| 语言 | Swift 原生 | Python |
| 集成难度 | 直接 Swift Package | 需 Python 运行时 |
| 速度 (large) | 快（ANE 硬件加速） | 1.02 秒（MLX GPU） |
| 流式支持 | 原生支持 | 社区方案 |
| macOS App 集成 | 无缝 | 需要桥接层 |

**评估：** mlx-whisper 适合 Python 研究/服务端场景，不适合 macOS 原生应用集成。

#### 6.3 Apple SFSpeechRecognizer (旧 API)

| 维度 | WhisperKit | SFSpeechRecognizer |
|------|-----------|-------------------|
| 中英混杂 | 优秀 | 差（只能选单语言） |
| 准确率 | 高 | 中等 |
| 隐私 | 完全离线 | 默认需网络（离线模式准确率低） |
| 流式 | 支持 | 支持 |
| 自定义模型 | 可选不同大小 | 不可 |

**评估：** WhisperKit 在中英混杂场景下明显优于 SFSpeechRecognizer，这也是项目选择 WhisperKit 的核心原因。

### 7. 内存与加载时间

#### 7.1 模型大小与内存占用

| 模型 | 磁盘大小 | 内存占用 (加载后) | 推理时额外内存 |
|------|---------|-------------------|---------------|
| tiny | ~75MB | ~150MB | +50-100MB |
| base | ~140MB | ~180MB | +100MB |
| small | ~460MB | ~500MB | +100-150MB |
| medium | ~1.5GB | ~2GB | +150-200MB |
| large-v3 (完整) | ~3GB | ~3.5GB | +200MB |
| **large-v3-v20240930_626MB** | **626MB** | **~1-1.5GB** | **+100-200MB** |

**峰值内存：** Argmax 论文确认压缩模型峰值内存低于 2GB，满足大多数设备的通用兼容性要求。

#### 7.2 模型加载时间

| 场景 | 耗时 | 备注 |
|------|------|------|
| 首次下载 | 视网速而定 | ~626MB 下载 + CoreML 编译 |
| 首次加载（ANE 编译） | 数分钟 | CoreML 需要为目标硬件编译一次 |
| 后续加载（缓存） | 2-3 秒 | 模型从本地缓存加载 |
| 预热 (prewarm) | 额外 1-2 秒 | 提前进行 model specialization |

**建议：** 项目已在 AppDelegate 启动时预加载模型，这是正确的做法。2-3 秒的加载时间对菜单栏工具而言完全可接受。

#### 7.3 磁盘空间

模型下载时需要约 2 倍磁盘空间（下载 + 解压/编译），编译完成后临时文件可清除。626MB 模型实际需要约 1.2GB 临时磁盘空间。

### 8. 项目当前配置分析

#### 8.1 模型选择评估

**当前模型：** `openai_whisper-large-v3-v20240930_626MB`

优点：
- 626MB 是合理的大小-准确率平衡点
- large-v3-v20240930 (turbo) 基座使用仅 4 层解码器，推理速度快
- 压缩至 626MB 保持了 ~95% 的原始质量 (QoI)
- 支持中英混杂识别

潜在问题：
- 这是**非 turbo 压缩版**（626MB），turbo 变体 (632MB) 可能有更低的流式延迟
- v20240930 对应 whisper-large-v3-turbo，但该模型在翻译任务上表现不佳（项目翻译已回退到云端 API，不受影响）

#### 8.2 DecodingOptions 评估

| 参数 | 项目值 | 默认值 | 评估 |
|------|--------|--------|------|
| temperature | 0.0 | 0.0 | 正确，贪婪解码最稳定 |
| temperatureIncrementOnFallback | 0.2 | 0.2 | 正确 |
| temperatureFallbackCount | 5 | 5 | 正确 |
| compressionRatioThreshold | 2.4 | 2.4 | 正确 |
| logProbThreshold | -1.0 | -1.0 | 正确 |
| firstTokenLogProbThreshold | -1.5 | -1.5 | 正确 |
| noSpeechThreshold | **0.3** | **0.6** | **需注意**：更宽容可能增加静音幻觉 |
| usePrefillPrompt | true | true | 正确 |
| usePrefillCache | true | true | 正确 |
| suppressBlank | true | true | 正确 |
| chunkingStrategy | .vad | nil | 正确，VAD 分块有助于长音频 |

**noSpeechThreshold = 0.3 的分析：**
- 项目将默认的 0.6 降低到 0.3，目的是避免正常语音被误判为噪音
- 这在中文低音量说话场景下有意义（中文语音特征与英文不同）
- 风险：可能导致长时间静音片段产生幻觉输出
- 建议：保持 0.3，但配合标签过滤和压缩比检测已形成足够的防线

#### 8.3 后处理评估

- 繁体->简体转换：正确，Whisper large-v3 中文输出常含繁体
- 标签过滤 (`[MUSIC]`, `[BLANK_AUDIO]`)：正确，这些标签在语音转文字场景中无用
- 正则替换 `\\[.*?\\]`：使用非贪婪匹配，不会误删正常方括号内容

### 9. 优化建议

#### 9.1 短期优化（无需代码大改）

**建议 1：考虑切换到 turbo 变体**
- 当前：`openai_whisper-large-v3-v20240930_626MB`
- 建议：`openai_whisper-large-v3-v20240930_turbo_632MB`
- 理由：turbo 后缀表示额外的流式优化（非压缩），仅多 6MB 但可能降低延迟
- 风险：低，同一基座模型

**建议 2：添加 promptTokens 提示**
- 可通过 `options.promptTokens` 传入上下文提示
- 例如对中文场景，可传入中文标点和常用词的 token，引导模型更好地输出中文
- 这对减少中英混杂时的语言混淆有帮助

**建议 3：利用 concurrentWorkerCount**
- macOS 默认 16 并发，对于短音频可适当降低以减少内存压力
- 长音频保持默认即可

#### 9.2 中期优化

**建议 4：关注 distil-whisper 系列**
- `distil-whisper_distil-large-v3_turbo_600MB`：蒸馏模型，仅 2 层解码器
- 速度比 large-v3-turbo 快约 1.5 倍
- 短音频转录准确率略优，长音频略逊 ~1%
- 适合对延迟敏感的实时场景

**建议 5：实现模型自动选择**
- 根据音频长度选择不同策略：短音频（<30s）用当前模型直接转录，长音频（>30s）启用 VAD 分块
- 项目已使用 VAD 分块，这点已经做对了

**建议 6：添加幻觉后处理检测**
- 在 transcribe 返回后，额外检测重复模式（如连续 3 次以上相同短语）
- 如果检测到重复，可尝试截断或用更高温度重新转录该片段

#### 9.3 长期关注

**建议 7：关注 Apple SpeechAnalyzer (macOS 26)**
- 当 macOS 26 正式发布后，评估将 SpeechAnalyzer 作为备选方案
- 优势：更快、无需下载模型、系统级优化
- 劣势：仅 10 种语言，可能不支持中文
- 可作为英文场景的快速路径

**建议 8：关注 WhisperKit 新版本**
- v0.16.0 引入了 TTSKit (TTS)
- v0.17.0 引入了 SpeakerKit (说话人分离)
- 后续版本可能引入更多压缩模型和多语言优化
- 建议定期更新 WhisperKit 依赖

**建议 9：Argmax 论文中的 d750 模型**
- Argmax 论文提到专门针对 5 种语言（英、德、日、中、法）微调的 d750 变体
- 如果该模型在 Hugging Face 上发布，建议测试其中文准确率
- 可能比通用 large-v3-turbo 在中文上表现更好

### 10. 多语言支持情况

**Whisper large-v3-turbo 支持的语言数量：** 100+

**中文支持详情：**
- 使用 CER (字符错误率) 而非 WER (词错误率) 评估
- large-v3-turbo 中文准确率接近 large-v2，无显著退化
- 繁体/简体均可识别，但输出可能混杂繁体（项目已通过后处理解决）

**已知问题：**
- turbo 模型在部分语言（泰语、粤语）上有较大退化
- 翻译任务表现不佳（turbo 训练时排除了翻译数据，项目已回退到云端 API）
- 中英混杂场景可能需要 `detectLanguage = true` 而非指定单一语言

**评估指标参考 (Common Voice 17)：**
- Argmax 在 22 种语言子集上进行了基准测试
- 特别包含了中文和日文的 CER 评估
- 微调后的模型在训练语言上 WER 改善或保持在 1% 以内

## 来源 (Sources)

- [WhisperKit GitHub 仓库](https://github.com/argmaxinc/WhisperKit) -- 官方源码、README 和发布说明
- [WhisperKit Releases](https://github.com/argmaxinc/WhisperKit/releases) -- 版本历史 v0.13.0 至 v0.17.0
- [WhisperKit Configurations.swift](https://github.com/argmaxinc/whisperkit/blob/main/Sources/WhisperKit/Core/Configurations.swift) -- DecodingOptions 和 WhisperKitConfig 完整定义
- [argmaxinc/whisperkit-coreml (Hugging Face)](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main) -- 全部 27 个 CoreML 模型变体列表
- [WhisperKit: On-device Real-time ASR with Billion-Scale Transformers (Argmax 论文)](https://arxiv.org/html/2507.10860v1) -- 性能基准、压缩技术、ANE 优化细节
- [Whisper Performance on Apple Silicon (Voicci)](https://www.voicci.com/blog/apple-silicon-whisper-performance.html) -- M1/M2/M3/M4 处理时间对比
- [Apple SpeechAnalyzer and Argmax WhisperKit (Argmax 博客)](https://www.argmaxinc.com/blog/apple-and-argmax) -- WhisperKit vs SpeechAnalyzer 官方对比
- [Apple's New Transcription APIs Blow Past Whisper (MacRumors)](https://www.macrumors.com/2025/06/18/apple-transcription-api-faster-than-whisper/) -- SpeechAnalyzer 速度测试
- [How accurate is Apple's new transcription AI? (9to5Mac)](https://9to5mac.com/2025/07/03/how-accurate-is-apples-new-transcription-ai-we-tested-it-against-whisper-and-parakeet/) -- SpeechAnalyzer vs Whisper 准确率对比
- [Bring advanced speech-to-text to your app with SpeechAnalyzer (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/277/) -- Apple 官方 SpeechAnalyzer 介绍
- [Whisper turbo model release (GitHub Discussion)](https://github.com/openai/whisper/discussions/2363) -- turbo 模型发布说明和多语言性能
- [openai/whisper-large-v3-turbo (Hugging Face)](https://huggingface.co/openai/whisper-large-v3-turbo) -- turbo 模型卡片
- [WhisperKit DecodingOptions 文档 (Swift Package Index)](https://swiftpackageindex.com/argmaxinc/WhisperKit/v0.13.0/documentation/whisperkit/decodingoptions) -- API 文档
- [Whisper hallucination discussion (OpenAI)](https://github.com/openai/whisper/discussions/679) -- 幻觉问题和解决方案讨论
- [WhisperKit Benchmarks Discussion](https://github.com/argmaxinc/WhisperKit/discussions/243) -- 社区基准测试数据
- [Whisper Large V3 Turbo: High-Accuracy and Fast Speech Recognition Model](https://medium.com/axinc-ai/whisper-large-v3-turbo-high-accuracy-and-fast-speech-recognition-model-be2f6af77bdc) -- turbo 模型速度基准
- [mac-whisper-speedtest (GitHub)](https://github.com/anvanvan/mac-whisper-speedtest) -- Apple Silicon 上不同 Whisper 实现的速度对比
- [Memory leak with Turbo model (WhisperKit Issue #265)](https://github.com/argmaxinc/WhisperKit/issues/265) -- 内存相关问题
- [Offline Speech Transcription Benchmark (VoicePing)](https://voiceping.net/en/blog/research-offline-speech-transcription-benchmark/) -- 跨平台离线转录基准
