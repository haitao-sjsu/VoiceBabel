# 翻译方案对比研究报告

## 摘要

WhisperUtil 项目当前实现了两种翻译方法：Whisper API 直接翻译（`/v1/audio/translations`，仅支持 whisper-1 模型，仅能翻译到英语）和两步法（gpt-4o-transcribe 转录 + gpt-4o-mini 文本翻译，支持任意目标语言）。两步法在翻译质量、语言灵活性方面显著优于直接翻译，但引入额外延迟和少量成本。项目当前默认使用两步法（`EngineeringOptions.translationMethod = "two-step"`），这是正确的选择。未来可考虑引入 Apple Translation Framework（免费、离线、隐私友好）作为本地翻译回退方案，或在翻译质量要求极高的场景下使用 DeepL API。

## 详细报告

### 1. 项目当前翻译架构

#### 1.1 代码结构

翻译功能的核心代码分布在以下文件中：

- **`Services/ServiceCloudOpenAI.swift`** -- 实现两种翻译方法：
  - `translate()` -- 方法一：调用 `/v1/audio/translations` 端点，强制使用 whisper-1 模型
  - `translateTwoStep()` -- 方法二：先调用 `transcribe()` 转录，再调用 `chatTranslate()` 用 gpt-4o-mini 翻译
  - `chatTranslate()` -- 私有方法，调用 Chat Completions API 进行文本翻译

- **`RecordingController.swift`** -- 翻译流程调度：
  - `translateAudio()` 方法根据 `config.translationMethod` 配置选择调用 `translate()` 或 `translateTwoStep()`
  - 翻译模式下不使用 Realtime 或 Local 模式，统一使用 Cloud HTTP API
  - 翻译结果不经过文本优化（`textCleanupMode` 跳过）

- **`Config/EngineeringOptions.swift`** -- 配置项：
  - `translationMethod`: `"whisper"` 或 `"two-step"`（当前默认 `"two-step"`）
  - `translationSourceLanguageFallback`: 未指定语言时的回退源语言（`"zh"`）

- **`Config/SettingsStore.swift`** -- 用户设置：
  - `translationTargetLanguage`: 翻译目标语言（默认 `"en"`）
  - 注意：当前 `translationTargetLanguage` 设置已存在于 SettingsStore 中，但 `chatTranslate()` 方法中硬编码了 "Translate to English"，尚未使用该设置

#### 1.2 调用流程

```
用户按下翻译热键
  -> RecordingController.beginRecording(mode: .translate)
  -> startNonStreamingRecording()（非流式录音）
  -> 用户松开热键 -> stopRecording() -> stopTranslationRecording()
  -> translateAudio()
     -> 如果 translationMethod == "two-step":
        -> whisperService.translateTwoStep()
           -> Step 1: transcribe()（gpt-4o-transcribe 转录为原文）
           -> Step 2: chatTranslate()（gpt-4o-mini 翻译为英文）
     -> 否则:
        -> whisperService.translate()（whisper-1 直接翻译为英文）
  -> handleResult() -> outputText() -> textInputter.inputText()
```

#### 1.3 已知问题

- `chatTranslate()` 中目标语言硬编码为英语（`"Translate to English"`），未使用 `SettingsStore.translationTargetLanguage` 设置
- 翻译模式不支持 Local/Realtime API 模式，强制使用 Cloud HTTP

### 2. 方法一：Whisper API 直接翻译

#### 2.1 工作原理

通过 OpenAI 的 `/v1/audio/translations` 端点，将音频直接翻译为英语文本。该端点接收音频文件（multipart/form-data 格式），内部同时完成语音识别和翻译，返回英文文本。

#### 2.2 技术细节

| 属性 | 详情 |
|------|------|
| API 端点 | `/v1/audio/translations` |
| 支持模型 | **仅 whisper-1**（gpt-4o-transcribe 不支持） |
| 输入格式 | 音频文件（mp3, mp4, mpeg, mpga, m4a, wav, webm） |
| 最大文件大小 | 25 MB |
| 输出语言 | **仅英语**（不可更改） |
| 输入语言 | Whisper 支持的 98 种语言 |
| 响应格式 | 文本 / JSON / SRT / VTT |

#### 2.3 优势

- **单次 API 调用**：音频直接到翻译结果，延迟低
- **实现简单**：一个 HTTP 请求即可完成
- **成本低**：仅收取音频处理费用（$0.006/分钟），无额外文本处理费

#### 2.4 劣势

- **仅支持翻译到英语**：这是最大限制，无法翻译到中文、日语等其他语言
- **使用旧模型**：强制使用 whisper-1，无法利用更新的 gpt-4o-transcribe 的高准确率
- **翻译质量有限**：Whisper 的翻译能力本质上是语音识别的副产物，不是专门的翻译模型，对上下文理解不如 LLM
- **不可控**：无法通过 system prompt 控制翻译风格、术语偏好等
- **无中间结果**：无法获取原文转录文本，用户无法验证识别是否正确

#### 2.5 质量评估

Whisper-1 的翻译本质上是在语音识别过程中通过特殊控制 token 切换到翻译任务。这种端到端的方式在简单句子上表现尚可，但在以下场景中质量下降明显：
- 专业术语和领域特定词汇
- 需要理解上下文的长句
- 口语化表达和俚语
- 涉及文化背景的内容

### 3. 方法二：两步法（转录 + GPT 翻译）

#### 3.1 工作原理

分两步完成翻译：
1. **Step 1 -- 转录**：使用 gpt-4o-transcribe（或用户配置的模型）将音频转录为源语言文本
2. **Step 2 -- 翻译**：将转录文本发送到 Chat Completions API（gpt-4o-mini），由 LLM 翻译为目标语言

#### 3.2 技术细节

| 属性 | 详情 |
|------|------|
| Step 1 API | `/v1/audio/transcriptions`（gpt-4o-transcribe） |
| Step 2 API | `/v1/chat/completions`（gpt-4o-mini） |
| 输入语言 | 98+ 种语言（Whisper 支持的所有语言） |
| 输出语言 | **任意语言**（通过 prompt 指定） |
| 可控性 | 高（可通过 system prompt 定制翻译风格） |

#### 3.3 当前实现的 Prompt

```
System: "You are a translator. Translate the following text to English.
         Output ONLY the translation, nothing else."
User: [转录文本]
```

#### 3.4 优势

- **翻译质量高**：GPT-4o-mini 是专门的语言模型，对上下文、语义、语法的理解远超 Whisper 的翻译功能
- **支持任意目标语言**：理论上可翻译到 GPT 支持的 80+ 种语言
- **可定制**：可通过 prompt 控制翻译风格（正式/口语）、术语偏好、格式要求等
- **转录质量高**：Step 1 使用 gpt-4o-transcribe，转录准确率优于 whisper-1
- **可获取中间结果**：可以同时保留原文和翻译结果
- **模型可升级**：翻译步骤可随时切换到更强的模型（gpt-4o, gpt-4.1 等）

#### 3.5 劣势

- **额外延迟**：需要两次 API 调用（串行），总延迟 = 转录延迟 + 翻译延迟
- **额外成本**：除音频转录费用外，还有 Chat Completions 的 token 费用
- **复杂度高**：两步流程增加了错误处理的复杂性（任一步骤可能失败）
- **依赖网络**：两步都需要网络，无法离线使用

#### 3.6 成本分析

以一段 30 秒的中文语音（约转录为 100 个中文字符，约 200 tokens）为例：

| 费用项目 | 计算 | 金额 |
|----------|------|------|
| Step 1: 转录 | 0.5 分钟 x $0.006/分钟 | $0.003 |
| Step 2: 输入 tokens | ~250 tokens x $0.15/1M | $0.0000375 |
| Step 2: 输出 tokens | ~200 tokens x $0.60/1M | $0.00012 |
| **总计** | | **~$0.0032** |

两步法的额外成本（Step 2）仅约 $0.00016，相对于转录费用几乎可以忽略不计。

### 4. 两种方法详细对比

| 维度 | 方法一：Whisper 直接翻译 | 方法二：两步法 |
|------|------------------------|--------------|
| **翻译质量** | 中等（Whisper 副产物） | 高（专业 LLM 翻译） |
| **目标语言** | 仅英语 | 任意语言 |
| **使用模型** | whisper-1（旧） | gpt-4o-transcribe + gpt-4o-mini |
| **API 调用次数** | 1 次 | 2 次（串行） |
| **延迟** | 低（单次调用） | 中（两次调用，约增加 0.5-2 秒） |
| **成本（30秒音频）** | ~$0.003 | ~$0.0032（+6%） |
| **可定制性** | 无 | 高（prompt 可控） |
| **中间结果** | 无 | 有（可保留原文） |
| **术语/风格控制** | 不支持 | 支持 |
| **实现复杂度** | 简单 | 中等 |
| **错误恢复** | 单点失败 | 两个失败点，但可分别处理 |
| **离线支持** | 不支持 | 不支持 |

**结论：两步法在几乎所有维度上优于直接翻译，且额外成本微乎其微。项目当前默认使用两步法是正确的选择。**

### 5. 其他可选翻译方案

#### 5.1 Apple Translation Framework

| 属性 | 详情 |
|------|------|
| 平台要求 | macOS 15 Sequoia+ / iOS 17.4+ |
| 支持语言 | ~20 种（英、中、日、韩、法、德、西、葡、意、俄等主要语言） |
| 运行方式 | 完全离线、设备端处理 |
| 成本 | 免费 |
| 隐私 | 数据不离开设备 |
| API | `TranslationSession` -- 支持批量翻译、流式翻译 |
| 翻译质量 | 中等偏上（不及 DeepL/GPT，但对常见语言对足够好） |

**优势：**
- 完全免费，无 API 费用
- 离线可用，不依赖网络
- 隐私保护 -- 所有数据在设备端处理
- 与 macOS 深度集成，API 简洁
- 可作为网络翻译的离线回退方案

**劣势：**
- 支持语言数量有限（约 20 种）
- 翻译质量不如 GPT-4o 或 DeepL
- 需要 macOS 15+（限制了兼容性）
- 语言模型需要用户首次使用时下载
- 不支持所有语言对的直接翻译（部分需通过英语中转）

**适用场景：** 适合作为 WhisperUtil 的离线翻译回退方案，类似于当前 WhisperKit 对 Cloud API 的回退策略。

#### 5.2 DeepL API

| 属性 | 详情 |
|------|------|
| 支持语言 | 31 种（以欧洲语言为主，含中日韩） |
| 翻译质量 | 高（欧洲语言尤为出色） |
| 定价 | 免费版：500,000 字符/月；Pro：$5.49/月 + $25/百万字符 |
| 特色 | 术语表、风格偏好、格式保留 |

**优势：**
- 欧洲语言翻译质量业界领先
- 支持术语表（Glossary），适合专业领域
- API 简单易用
- 免费版额度足够个人使用

**劣势：**
- 额外引入第三方 API 依赖
- 支持语言少于 GPT（31 vs 80+）
- 需要额外的 API key 管理
- 中文翻译质量不如其在欧洲语言上的表现

**适用场景：** 如果用户主要翻译欧洲语言（特别是英德、英法），DeepL 可能是比 GPT 更好的选择。

#### 5.3 本地翻译模型

##### Meta NLLB (No Language Left Behind)

| 属性 | 详情 |
|------|------|
| 支持语言 | 200+ 种 |
| 模型大小 | 600MB（distilled）~ 2.5GB（完整） |
| 推理框架 | CTranslate2, PyTorch MPS（Apple Silicon GPU 加速） |
| 许可证 | CC-BY-NC 4.0（非商业） |
| CoreML 版本 | 存在社区转换版（nllb-200-coreml-128） |

##### Meta M2M-100

| 属性 | 详情 |
|------|------|
| 支持语言 | 100 种（直接翻译，不经过英语中转） |
| 模型大小 | 418M ~ 12B 参数 |
| 推理框架 | CTranslate2, Hugging Face Transformers |

##### Meta SeamlessM4T v2

| 属性 | 详情 |
|------|------|
| 功能 | 语音到文本、语音到语音、文本到文本翻译 |
| 支持语言 | ~100 种 |
| 特色 | 端到端语音翻译，无需先转录 |
| 大小 | 较大，适合服务器端部署 |

**本地模型总体评估：**
- NLLB 的 CoreML 版本可在 macOS 上运行，但模型较大（~3GB）
- 翻译质量不如 GPT-4o 或 DeepL，但支持更多语言
- 适合对隐私要求极高、完全不能联网的场景
- Apple Silicon GPU 加速使本地推理速度可接受
- 集成复杂度较高，需要额外的模型管理逻辑

#### 5.4 使用更强的 GPT 模型翻译

当前两步法使用 gpt-4o-mini 进行翻译。可考虑升级到更强模型：

| 模型 | 输入价格/1M tokens | 输出价格/1M tokens | 翻译质量 | 延迟 |
|------|-------------------|-------------------|---------|------|
| gpt-4o-mini | $0.15 | $0.60 | 良好 | 低 |
| gpt-4o | $2.50 | $10.00 | 优秀 | 中 |
| gpt-4.1 | ~$2.00 | ~$8.00 | 优秀 | 中 |
| gpt-4.1-mini | ~$0.40 | ~$1.60 | 良好+ | 低 |
| gpt-4.1-nano | ~$0.10 | ~$0.40 | 一般+ | 极低 |

对于短文本翻译（语音转录通常几十到几百字），即使使用 gpt-4o 成本也极低。如果对翻译质量有更高要求，可考虑将翻译模型升级为 gpt-4o 或 gpt-4.1。

#### 5.5 Google Cloud Translation API

| 属性 | 详情 |
|------|------|
| 支持语言 | 130+ 种 |
| 定价 | $20/百万字符 |
| 特色 | 语言自动检测、自适应翻译 |
| 质量 | 中等偏上（通用场景表现稳定） |

Google Translate 在语言覆盖范围上最广，但翻译质量在大多数语言对上不如 DeepL 和 GPT。

### 6. 推荐方案与优化建议

#### 6.1 短期优化（当前架构内）

1. **修复目标语言硬编码问题**：`chatTranslate()` 应使用 `SettingsStore.translationTargetLanguage` 而非硬编码 "English"。当前用户设置界面已有目标语言选项，但后端未使用。

2. **优化翻译 prompt**：当前 prompt 过于简单，建议增强：
   ```
   You are a professional translator. Translate the following spoken text
   to {targetLanguage}. The text is a speech transcription, so it may
   contain filler words or incomplete sentences. Produce a natural,
   fluent translation. Output ONLY the translation.
   ```

3. **保留中间转录结果**：`translateTwoStep()` 完成 Step 1 后记录原文转录，便于用户对照检查。

4. **考虑翻译模型升级**：对于翻译质量敏感的用户，提供选项将翻译模型从 gpt-4o-mini 升级到 gpt-4o 或 gpt-4.1-mini（成本增加极少）。

#### 6.2 中期改进

5. **引入 Apple Translation Framework 作为离线回退**：
   - 当网络不可用时，使用 Apple Translation Framework 进行本地翻译
   - 与现有的 Cloud -> Local 回退策略一致
   - 需要 macOS 15+，但该版本已是主流
   - 实现路径：本地 WhisperKit 转录 -> Apple Translation Framework 翻译

6. **并行预翻译**：在用户录音时就可以准备翻译环境（如预热连接），减少感知延迟。

#### 6.3 长期探索

7. **DeepL 集成**：为欧洲语言翻译提供 DeepL 选项，适合商务/专业场景。

8. **端到端语音翻译**：关注 SeamlessM4T 等端到端模型的发展，未来可能在单次推理中完成语音到翻译文本的转换，消除两步法的串行延迟。

9. **流式翻译**：Realtime API 模式下实现实时翻译（边说边翻译），但这需要 OpenAI 在 Realtime API 中原生支持翻译功能。

#### 6.4 方案优先级总结

| 优先级 | 方案 | 难度 | 收益 |
|--------|------|------|------|
| P0 | 修复目标语言硬编码 | 低 | 高（解锁多语言翻译） |
| P1 | 优化翻译 prompt | 低 | 中（提升翻译质量） |
| P1 | 保留中间转录结果 | 低 | 中（提升用户体验） |
| P2 | Apple Translation 离线回退 | 中 | 中（离线翻译能力） |
| P2 | 翻译模型可配置化 | 低 | 低（灵活性） |
| P3 | DeepL 集成 | 中 | 低（细分场景） |
| P3 | 端到端语音翻译探索 | 高 | 未来潜力 |

## 来源 (Sources)

- [Speech to text - OpenAI API](https://platform.openai.com/docs/guides/speech-to-text) -- Whisper API 官方文档，translations 端点说明
- [Introducing next-generation audio models in the API - OpenAI](https://openai.com/index/introducing-our-next-generation-audio-models/) -- gpt-4o-transcribe 发布公告及性能对比
- [OpenAI API Pricing](https://developers.openai.com/api/docs/pricing) -- 各模型定价信息
- [GPT-4o Transcribe Model - OpenAI API](https://developers.openai.com/api/docs/models/gpt-4o-transcribe) -- gpt-4o-transcribe 模型文档
- [Gpt-4o-mini-transcribe and gpt-4o-transcribe not as good as whisper - OpenAI Community](https://community.openai.com/t/gpt-4o-mini-transcribe-and-gpt-4o-transcribe-not-as-good-as-whisper/1153905) -- 社区对新旧模型的对比讨论
- [Translation - Apple Developer Documentation](https://developer.apple.com/documentation/translation/) -- Apple Translation Framework 官方文档
- [Free, on-device translations with the Swift Translation API](https://www.polpiella.dev/swift-translation-api/) -- Apple Translation Framework 实践指南
- [From Paid APIs to Native: Migrating to Apple's Translation Framework](https://toyboy2.medium.com/from-paid-apis-to-native-migrating-to-apples-translation-framework-in-swiftui-c31157da2783) -- 从付费 API 迁移到 Apple 原生翻译的经验
- [DeepL API plans - DeepL Help Center](https://support.deepl.com/hc/en-us/articles/360021200939-DeepL-API-plans) -- DeepL API 定价
- [Best AI translation software for 2026 - Gridly](https://www.gridly.com/blog/best-ai-translation-software-explore-these-9-solutions/) -- 2026 年 AI 翻译工具综合评测
- [Machine Translation Accuracy 2026: Google Translate vs DeepL vs ChatGPT](https://intlpull.com/blog/machine-translation-accuracy-2026-benchmark) -- 翻译准确率基准测试
- [SeamlessM4T - Meta AI](https://ai.meta.com/research/publications/seamlessm4t-massively-multilingual-multimodal-machine-translation/) -- Meta 端到端语音翻译模型
- [cstr/nllb-200-coreml-128 - Hugging Face](https://huggingface.co/cstr/nllb-200-coreml-128) -- NLLB CoreML 转换版本
- [nllb-localized-lang-translator - GitHub](https://github.com/sibi-seeni/nllb-localized-lang-translator) -- NLLB 在 Apple Silicon Mac 上的 GPU 加速实现
- [Realtime video transcription and translation with Whisper and NLLB on MacBook Air](https://medium.com/@GenerationAI/realtime-video-transcription-and-translation-with-whisper-and-nllb-on-macbook-air-31db4c62c074) -- Whisper + NLLB 本地翻译实践
