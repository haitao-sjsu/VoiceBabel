# 文本润色/清理方案研究报告

## 摘要

项目当前使用 GPT-4o-mini 通过 OpenAI Chat Completions API 进行文本清理，支持三种润色模式（自然/正式/口语）。截至 2026 年 3 月，OpenAI 已推出更快更便宜的替代模型（GPT-4.1-nano、GPT-5-nano、GPT-5.4-nano），延迟可降低 50% 以上，成本降低 80-95%。本地方案方面，Apple MLX Swift 框架已成熟，可通过 mlx-swift-lm 包集成 Qwen3-4B-4bit 等小型模型实现零成本、零延迟的文本清理，但需要约 2-4GB 内存开销。综合考虑延迟敏感场景，推荐短期迁移到 GPT-4.1-nano 或 GPT-5-nano，中期集成 MLX Swift 本地模型作为离线备选。

## 详细报告

### 1. 项目当前方案分析

#### 1.1 实现架构

文本清理功能由 `ServiceTextCleanup.swift` 实现，核心流程：

```
录音完成 → 转录文本 → ServiceTextCleanup.cleanup() → GPT-4o-mini API → 清理后文本 → 输出
```

- **模型**: 硬编码为 `gpt-4o-mini`（第 114 行）
- **API 端点**: `https://api.openai.com/v1/chat/completions`（定义在 Constants.swift）
- **temperature**: 0.3（偏保守，减少创造性改写）
- **超时策略**: 动态计算，`min(max(audioDuration/60 * 10, 5), 90)` 秒

#### 1.2 三种润色模式

| 模式 | 用途 | Prompt 策略 |
|------|------|-------------|
| neutral（自然润色） | 去除填充词/口误，保持原始语气 | 移除 um/uh/那个/就是等，修正语法标点 |
| formal（正式风格） | 商务邮件等正式场景 | 改写为完整句式，避免口语和缩写 |
| casual（口语风格） | 轻松对话 | 保持简洁友好，使用常见缩写 |

#### 1.3 调用流程

在 `RecordingController.swift` 的 `outputText()` 方法中统一处理：
- 翻译模式跳过文本优化
- 文本优化失败时回退到原始文本（不丢失转录结果）
- Realtime 模式开启文本优化时，会抑制 delta 逐词输出，等待完整文本后统一处理

#### 1.4 当前方案的问题

- **GPT-4o-mini 即将退役**: 已从 ChatGPT 界面移除（2026.2.13），API 端虽仍可用但未来不确定
- **延迟开销**: 每次请求约 500-1500ms（TTFT + 生成时间），对短文本尤其明显
- **成本**: $0.15/1M input + $0.60/1M output，虽然不贵但完全可以更低
- **依赖网络**: 无网络时文本优化不可用

### 2. 云端轻量模型对比

#### 2.1 OpenAI 模型系列（截至 2026 年 3 月）

| 模型 | Input/1M | Output/1M | 速度 (tok/s) | TTFT | 上下文窗口 | 状态 |
|------|----------|-----------|-------------|------|-----------|------|
| gpt-4o-mini | $0.15 | $0.60 | ~85 | ~800ms | 128K | 即将退役 |
| gpt-4.1-nano | $0.10 | $0.40 | ~120+ | <500ms | 200K | 可用 |
| gpt-4.1-mini | $0.40 | $1.60 | ~100 | ~600ms | 200K | 可用 |
| gpt-5-nano | $0.05 | $0.40 | ~157 | ~650ms | 400K | 可用 |
| gpt-5.4-nano | $0.20 | $1.25 | ~213 | ~410ms | 400K | 最新推荐 |
| gpt-5-mini | $0.25 | $2.00 | ~130 | ~550ms | 400K | 可用 |

#### 2.2 评估（针对文本清理任务）

**最佳性价比**: GPT-5-nano（$0.05/$0.40），速度快、价格最低、质量足够
**最低延迟**: GPT-5.4-nano（TTFT 410ms），但价格较高
**平衡之选**: GPT-4.1-nano（$0.10/$0.40），延迟低，价格合理，质量稳定

对于语音转文字后处理这种简单任务（去填充词、修标点），nano 级模型完全胜任，无需 mini 或更大模型。

### 3. 其他云端 LLM 方案

#### 3.1 价格对比

| 提供商 | 模型 | Input/1M | Output/1M | 特点 |
|--------|------|----------|-----------|------|
| Google | Gemini 2.0 Flash | $0.10 | $0.40 | 速度极快，价格与 GPT-4.1-nano 相当 |
| Google | Gemini 2.5 Flash-Lite | $0.10 | $0.40 | 支持上下文缓存（90% 折扣） |
| Google | Gemini 2.5 Flash | $0.30 | $2.50 | 更强推理能力 |
| Anthropic | Claude Haiku 4.5 | $1.00 | $5.00 | 质量高但价格较贵 |
| DeepSeek | DeepSeek V3.2 | $0.28 | $0.42 | 中文能力突出 |

#### 3.2 可行性评估

- **Gemini 2.0 Flash / 2.5 Flash-Lite**: 强烈推荐考虑。价格与 GPT-4.1-nano 相同，Google 的 Gemini Flash 系列以超低延迟著称（throughput 达 146-173 tok/s）。但需要引入 Google API 密钥，增加了配置复杂度。
- **Claude Haiku 4.5**: 文本处理质量很高，TTFT 极低（~597ms 且非常稳定），但价格是 GPT-nano 的 10-20 倍，对于简单文本清理任务不划算。
- **DeepSeek V3.2**: 中文处理能力强，价格合理。但 API 稳定性和延迟（服务器在中国）可能是问题。

#### 3.3 关键考量

项目当前只使用 OpenAI API 密钥。引入其他提供商需要：
- 新增 API 密钥配置
- 修改 ServiceTextCleanup 支持多后端
- 处理不同的 API 格式和错误码

**建议**: 优先在 OpenAI 生态内升级（nano 模型），除非有特殊需求再引入其他提供商。

### 4. 本地 LLM 方案

#### 4.1 Apple MLX Swift 框架

MLX 是 Apple 官方的机器学习框架，专为 Apple Silicon 优化。

**mlx-swift-lm 集成方式**:
```swift
// Package.swift 依赖
.package(url: "https://github.com/ml-explore/mlx-swift-lm/", .upToNextMinor(from: "2.29.1"))

// 使用示例
let model = try await loadModel(id: "mlx-community/Qwen3-4B-4bit")
let session = ChatSession(model)
let result = try await session.respond(to: systemPrompt + "\n" + userText)
```

**优势**:
- 原生 Swift 集成，可直接嵌入 macOS 应用
- HuggingFace 上有 1000+ 预转换的 MLX 模型
- 支持 4-bit 量化，显著降低内存占用
- 完全离线，数据不离开设备
- Apple Silicon 优化，利用 GPU 和 Neural Engine

**劣势**:
- 首次加载模型需下载（几百 MB 到几 GB）
- 常驻内存占用（4-bit Qwen3-4B 约 2-3GB）
- 推理速度受限于设备硬件

#### 4.2 Apple Foundation Models 框架

Apple 在 macOS 26 / iOS 26 引入的系统级 LLM 框架：
- 内置 ~3B 参数模型，2-bit 量化
- 无需额外下载模型
- 通过 Foundation Models framework 几行代码即可调用
- 擅长文本提炼、摘要、实体提取等任务

**限制**:
- 仅支持 macOS 26+（目前仍为 beta）
- 模型能力有限，非通用聊天机器人
- 不支持旧系统

**评估**: 长期来看是最优雅的本地方案，但需要等 macOS 26 正式发布且用户升级。

#### 4.3 Core ML 方案

可通过 coremltools 将 HuggingFace 模型转换为 Core ML 格式：
- Llama-3.1-8B-Instruct 在 M1 Max 上约 33 tok/s
- 支持 ANE（Apple Neural Engine）加速
- 模型文件较大，分发不便

**评估**: 不如 MLX Swift 方便，MLX 已成为 Apple Silicon 上的事实标准。

#### 4.4 可用的小型模型性能

在 Apple Silicon 上运行小型模型的预期性能：

| 模型 | 大小 | 4-bit 内存 | M1 tok/s | M3 tok/s | 文本清理质量 |
|------|------|-----------|----------|----------|------------|
| Qwen2.5-0.5B-Instruct | 0.5B | ~0.4GB | ~60+ | ~80+ | 基础，适合简单纠错 |
| Qwen2.5-1.5B-Instruct | 1.5B | ~1GB | ~40-50 | ~60+ | 中等，多语言支持好 |
| Qwen3-4B-4bit | 4B | ~2.5GB | ~25-30 | ~40+ | 良好，推荐 |
| Llama-3.2-3B-Instruct-4bit | 3B | ~2GB | ~30-40 | ~50+ | 良好，英文优秀 |
| Phi-3-mini-4k (3.8B) | 3.8B | ~2.3GB | ~25-30 | ~40+ | 良好，指令跟随强 |
| SmolLM2-1.7B-Instruct | 1.7B | ~1GB | ~40-50 | ~60+ | 中等偏上 |

**关键数据**:
- 对于文本清理任务，输入 50-200 tokens，输出也是 50-200 tokens
- 以 40 tok/s 计算，生成 100 tokens 仅需 2.5 秒
- TTFT（首 token 时间）通常在 0.5-2 秒

#### 4.5 本地方案延迟估算

对于典型文本清理任务（输入 100 tokens 的短句）：

| 阶段 | 耗时 |
|------|------|
| 模型已加载后的 TTFT | 0.3-1.0s |
| 生成 100 tokens | 1.5-3.0s |
| **总延迟** | **2.0-4.0s** |

对比云端方案（GPT-4.1-nano）：
- 网络延迟 + TTFT: 0.5-1.0s
- 生成 100 tokens: 0.5-1.0s
- **总延迟**: 1.0-2.0s

**结论**: 本地方案延迟约为云端的 1.5-2 倍，但无网络依赖和费用。

### 5. 专门的文本纠错工具

#### 5.1 传统语法检查工具

| 工具 | 类型 | 中文支持 | 延迟 | 成本 | 适用场景 |
|------|------|---------|------|------|---------|
| LanguageTool | 开源/API | 有限 | ~100-300ms | 免费(公共API)/付费(商业) | 语法拼写检查 |
| GrammarBot | API | 无 | ~200ms | 免费层有限 | 英文语法 |
| Sapling AI | API | 无 | ~150ms | 付费 | 商业写作 |

**LanguageTool 详情**:
- 开源 Java 项目，可本地部署
- API 格式简单（HTTP + JSON）
- 支持 30+ 语言（但中文支持有限）
- 公共 API 有速率限制
- 商业 API 起价 $4.99/月

**评估**: 传统工具的核心问题是**不理解语音转文字的特殊需求**——它们擅长修正已有文本的拼写和语法错误，但不擅长：
- 识别和移除口语填充词（嗯、那个、就是说）
- 处理语音识别产生的同音字错误
- 理解自我纠正（"我要去北京...不，上海"→"我要去上海"）
- 调整文体风格（如将口语改为书面语）

#### 5.2 专门的语音后处理模型

目前没有广泛使用的专用"语音转文字后处理模型"。业界做法：

1. **规则引擎 + LLM 混合**: 用正则表达式处理明确的填充词删除，用 LLM 处理需要理解的改写
2. **多模型并行**: 同时运行 2-3 个模型，用 LLM 调和差异，可减少 40% 关键错误
3. **领域微调**: 在特定领域的语音转文字对（原始→清理后）上微调小型 LLM

#### 5.3 基于规则的方法 vs LLM 方法

| 维度 | 规则方法 | LLM 方法 |
|------|---------|---------|
| 延迟 | 极低（<10ms） | 中等（500ms-4s） |
| 成本 | 零 | 按量付费或本地计算 |
| 填充词移除 | 需要维护词表，匹配死板 | 理解语境，精准移除 |
| 语法修正 | 有限 | 优秀 |
| 风格改写 | 不可能 | 擅长 |
| 中文处理 | 分词困难，规则难穷举 | 原生支持 |
| 维护成本 | 随语言/场景增加而激增 | 换 prompt 即可 |

**结论**: 对于本项目需要的三种模式（自然/正式/口语），LLM 方法是唯一实际可行的方案。规则方法可作为补充（如预处理阶段移除明确的填充词），但不能替代 LLM。

### 6. 延迟-成本-质量权衡分析

#### 6.1 各方案综合评分

| 方案 | 延迟 | 成本/月* | 质量 | 离线 | 集成难度 | 综合评价 |
|------|------|---------|------|------|---------|---------|
| GPT-4o-mini（当前） | 1-2s | ~$0.10 | ★★★★ | 否 | 已有 | 即将退役 |
| GPT-4.1-nano | 0.8-1.5s | ~$0.05 | ★★★☆ | 否 | 极低 | **短期首选** |
| GPT-5-nano | 1-1.5s | ~$0.04 | ★★★★ | 否 | 极低 | 性价比最高 |
| GPT-5.4-nano | 0.6-1.2s | ~$0.15 | ★★★★ | 否 | 极低 | 延迟最优 |
| Gemini 2.0 Flash | 0.8-1.5s | ~$0.05 | ★★★☆ | 否 | 中等 | 需要新 API 密钥 |
| Claude Haiku 4.5 | 1-2s | ~$0.60 | ★★★★★ | 否 | 中等 | 价格过高 |
| MLX 本地 (Qwen3-4B) | 2-4s | $0 | ★★★☆ | 是 | 中等 | **离线方案首选** |
| MLX 本地 (Qwen2.5-1.5B) | 1.5-3s | $0 | ★★★ | 是 | 中等 | 轻量离线方案 |
| Apple Foundation Models | 1-3s | $0 | ★★★ | 是 | 低 | 需 macOS 26+ |
| LanguageTool | 0.1-0.3s | ~$5 | ★★ | 可** | 中等 | 不适合语音后处理 |

\* 按每天 100 次、每次约 200 tokens 估算
\*\* LanguageTool 可本地部署但需要 Java 环境

#### 6.2 延迟分析

对于语音转文字场景，用户期望：
- 短句（<10秒录音）: 总处理时间 <2秒
- 中等句子（10-30秒）: 总处理时间 <3秒
- 长段落（>30秒）: 总处理时间 <5秒

文本清理增加的额外延迟：
- **云端 nano 模型**: +0.5-1.5s（可接受）
- **本地 4B 模型**: +2-4s（对短句偏长）
- **本地 1.5B 模型**: +1.5-3s（勉强可接受）

#### 6.3 建议的优化策略

1. **流式输出**: 文本清理也使用 streaming，用户可以看到逐步出现的文本
2. **异步处理**: 转录完成后立即输出原始文本，后台清理完毕后替换
3. **缓存**: 对相同/相似输入缓存清理结果
4. **预热**: 本地模型保持常驻内存，避免每次加载

### 7. 推荐方案

#### 7.1 短期方案（立即可做）

**将 `gpt-4o-mini` 替换为 `gpt-4.1-nano`**

改动极小——只需修改 `ServiceTextCleanup.swift` 第 114 行：
```swift
// 当前
"model": "gpt-4o-mini",
// 改为
"model": "gpt-4.1-nano",
```

收益：
- 延迟降低约 30-50%
- 成本降低约 50%
- API 兼容，无需其他改动
- 避免 gpt-4o-mini 退役风险

或者考虑 `gpt-5-nano`（更便宜、质量更好，但延迟略高于 4.1-nano）。

**建议**: 将模型名称提取到 `EngineeringOptions.swift` 中作为可配置项，方便后续切换。

#### 7.2 中期方案（1-2 个月）

**集成 MLX Swift 本地模型作为备选**

架构设计：
```
ServiceTextCleanup
├── CloudCleanup（当前 API 方案，默认）
└── LocalCleanup（MLX Swift 本地模型）
    └── Qwen3-4B-4bit 或 Qwen2.5-1.5B-Instruct
```

触发条件：
- 用户在设置中选择"本地文本优化"
- 或云端 API 超时时自动回退（类似现有的 Cloud→Local 转录回退）

集成步骤：
1. 添加 `mlx-swift-lm` Swift Package 依赖
2. 创建 `ServiceTextCleanupLocal.swift`
3. 在 EngineeringOptions 中添加清理后端选择
4. 处理模型下载和加载（首次使用时从 HuggingFace 下载）

#### 7.3 长期方案（macOS 26 发布后）

**接入 Apple Foundation Models 框架**

当 macOS 26 正式发布后，可以用系统内置的 3B 模型替代自行下载的模型：
- 无需额外下载
- 系统级优化，性能最佳
- 通过 @Generable 宏可以结构化输出
- 但需要放弃对旧系统的支持

#### 7.4 不推荐的方案

- **Claude Haiku 4.5**: 质量好但价格是 nano 模型的 10-20 倍，不值得
- **LanguageTool / GrammarBot**: 不适合语音后处理场景，中文支持差
- **Core ML 手动转换**: MLX Swift 更方便，无需手动转换模型
- **规则引擎**: 无法实现 formal/casual 风格改写，维护成本高

## 来源 (Sources)

- [OpenAI API Pricing](https://openai.com/api/pricing/) — OpenAI 官方模型定价页面
- [OpenAI GPT-4.1 Announcement](https://openai.com/index/gpt-4-1/) — GPT-4.1 系列发布说明
- [LLM API Pricing March 2026 (TLDL)](https://www.tldl.io/resources/llm-api-pricing-2026) — 2026年3月全面的 LLM 定价对比
- [GPT-4o Mini vs GPT-4.1 Nano (DocsBot)](https://docsbot.ai/models/compare/gpt-4o-mini/gpt-4-1-nano) — 模型性能对比数据
- [Performance Showdown of Low-Cost LLMs (Medium)](https://medium.com/@adelbasli/a-performance-showdown-of-low-cost-llms-gpt-4o-mini-gpt-4-1-nano-and-beyond-32f0d9e54f11) — 低成本 LLM 性能评测
- [LLM API Latency Benchmarks 2026](https://www.kunalganglani.com/blog/llm-api-latency-benchmarks-2026) — Claude Haiku / Gemini Flash 延迟评测
- [Gemini 2.5 Flash vs Claude 4.5 Haiku (Appaca)](https://www.appaca.ai/resources/llm-comparison/gemini-2.5-flash-vs-claude-4.5-haiku) — Gemini Flash 和 Claude Haiku 对比
- [GPT-5 Nano (OpenAI)](https://platform.openai.com/docs/models/gpt-5-nano) — GPT-5 Nano 模型文档
- [GPT-5.4 Mini and Nano (OpenAI)](https://openai.com/index/introducing-gpt-5-4-mini-and-nano/) — GPT-5.4 系列发布说明
- [Retiring GPT-4o and Other Models (OpenAI)](https://help.openai.com/en/articles/20001051-retiring-gpt-4o-and-other-chatgpt-models) — GPT-4o 系列退役说明
- [MLX Swift (GitHub)](https://github.com/ml-explore/mlx-swift) — Apple MLX Swift 框架源码
- [MLX Swift LM (GitHub)](https://github.com/ml-explore/mlx-swift-lm) — MLX Swift LLM 推理库
- [Explore LLMs on Apple Silicon with MLX (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/298/) — Apple 官方 MLX + LLM 教程
- [Apple Foundation Models Framework](https://developer.apple.com/documentation/FoundationModels) — Apple Foundation Models 开发者文档
- [Apple Foundation Models Tech Report 2025](https://machinelearning.apple.com/research/apple-foundation-models-tech-report-2025) — Apple 基础模型技术报告
- [On-Device Llama 3.1 with Core ML](https://machinelearning.apple.com/research/core-ml-on-device-llama) — Core ML 本地 LLM 推理研究
- [MLX on Apple Silicon Guide](https://www.markus-schall.de/en/2025/09/mlx-on-apple-silicon-as-local-ki-compared-with-ollama-co/) — MLX 在 Apple Silicon 上的性能实测
- [Local LLMs Apple Silicon Mac 2026 (SitePoint)](https://www.sitepoint.com/local-llms-apple-silicon-mac-2026/) — 本地 LLM 在 Mac 上的运行指南
- [LLM Inference Speed Comparison (Ajit Singh)](https://singhajit.com/llm-inference-speed-comparison/) — Qwen2 / Llama 3.1 本地推理速度对比
- [LocalLLMClient Swift Package](https://dev.to/tattn/localllmclient-a-swift-package-for-local-llms-using-llamacpp-and-mlx-1bcp) — Swift 本地 LLM 客户端库
- [LanguageTool API](https://languagetool.org/proofreading-api) — LanguageTool 语法检查 API
- [GrammarBot](https://grammarbot.io/) — GrammarBot 语法检查 API
- [Qwen2.5 LLM Blog](https://qwenlm.github.io/blog/qwen2.5-llm/) — Qwen2.5 模型系列说明
- [AssemblyAI Speech-to-Text Guide](https://www.assemblyai.com/blog/speech-to-text-ai-a-complete-guide-to-modern-speech-recognition-technology) — 语音转文字后处理最佳实践
