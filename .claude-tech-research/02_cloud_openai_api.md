# OpenAI Cloud Transcription API 研究报告

## 摘要

OpenAI 当前提供 5 个转录模型：whisper-1（传统）、gpt-4o-transcribe、gpt-4o-mini-transcribe、gpt-4o-mini-transcribe-2025-12-15（最新快照）、gpt-4o-transcribe-diarize（说话人识别）。2025 年 12 月发布的 gpt-4o-mini-transcribe-2025-12-15 快照是目前 OpenAI 官方推荐的首选模型，相比 whisper-1 减少约 89% 的幻觉，WER 降低约 35%，价格仅为 $0.003/分钟（whisper-1 的一半）。项目当前使用 gpt-4o-transcribe，建议评估切换至 gpt-4o-mini-transcribe 以获得更好的性价比和更低的幻觉率，尤其对中文转录有显著改善。翻译 API（/v1/audio/translations）仍然仅支持 whisper-1 模型，项目已有的两步翻译法是正确的应对方案。

## 详细报告

### 1. 可用转录模型概览

| 模型 | 发布时间 | 类型 | 说明 |
|------|---------|------|------|
| `whisper-1` | 2023 | 传统模型 | 基于开源 Whisper V2，功能最全面 |
| `gpt-4o-transcribe` | 2025-03 | GPT-4o 级别 | 基于 GPT-4o 的高精度转录 |
| `gpt-4o-mini-transcribe` | 2025-03 | GPT-4o-mini 级别 | 轻量版，性价比高（当前指向 2025-12-15 快照） |
| `gpt-4o-mini-transcribe-2025-03-20` | 2025-03 | GPT-4o-mini 级别 | 初始快照（仍可用） |
| `gpt-4o-mini-transcribe-2025-12-15` | 2025-12 | GPT-4o-mini 级别 | 最新快照，OpenAI 推荐首选 |
| `gpt-4o-transcribe-diarize` | 2025-10 | GPT-4o 级别 + 说话人识别 | 支持说话人分离 |

**OpenAI 当前推荐**：官方建议使用 `gpt-4o-mini-transcribe` 而非 `gpt-4o-transcribe` 以获得最佳效果。2025-12-15 快照在噪音环境和多语言场景中表现显著提升。

### 2. API 参数与限制对比

#### 基本限制（所有模型共用）

| 项目 | 限制 |
|------|------|
| 最大文件大小 | 25 MB |
| 支持音频格式 | flac, mp3, mp4, mpeg, mpga, m4a, ogg, wav, webm |
| API 端点 | `POST /v1/audio/transcriptions` |

#### 参数支持对比

| 参数 | whisper-1 | gpt-4o-transcribe | gpt-4o-mini-transcribe | gpt-4o-transcribe-diarize |
|------|-----------|-------------------|----------------------|--------------------------|
| `file` | 必填 | 必填 | 必填 | 必填 |
| `model` | 必填 | 必填 | 必填 | 必填 |
| `language` | ISO-639-1 | ISO-639-1 | ISO-639-1 | ISO-639-1 |
| `prompt` | 支持 | 支持 | 支持 | 不支持 |
| `temperature` | 0-1 | 0-1 | 0-1 | 不适用 |
| `response_format` | json, text, srt, verbose_json, vtt | json, text | json, text | json, text, diarized_json |
| `timestamp_granularities` | word, segment | 不支持 | 不支持 | 不支持 |
| `chunking_strategy` | 不适用 | 不适用 | 不适用 | 必填（音频 > 30s） |
| 上下文窗口 | N/A | 16,000 tokens | N/A | N/A |
| 最大输出 tokens | N/A | 2,000 tokens | N/A | N/A |

#### Realtime API 支持

| 模型 | Realtime API 支持 |
|------|-------------------|
| `whisper-1` | 支持（转录模式） |
| `gpt-4o-transcribe` | 支持（转录模式） |
| `gpt-4o-mini-transcribe` | 支持（转录模式） |
| `gpt-4o-transcribe-diarize` | 不支持 |

#### 翻译 API 支持（/v1/audio/translations）

| 模型 | 翻译 API 支持 |
|------|---------------|
| `whisper-1` | 支持（唯一支持的模型） |
| `gpt-4o-transcribe` | 不支持 |
| `gpt-4o-mini-transcribe` | 不支持 |
| `gpt-4o-transcribe-diarize` | 不支持 |

### 3. 准确率 (WER) 对比

#### 官方/第三方基准测试数据

| 模型 | WER（综合） | 说明 |
|------|-----------|------|
| `gpt-4o-transcribe` | ~2.46% | 第三方基准测试中的顶级表现 |
| `gpt-4o-mini-transcribe-2025-12-15` | 比 whisper-1 低约 35% | Common Voice / FLEURS 基准 |
| `whisper-1` (Whisper V2) | ~7.4% | Whisper Large V3 的近似数值 |

#### 幻觉率对比（2025-12-15 快照）

| 对比基准 | 幻觉减少幅度 |
|---------|------------|
| 相比 whisper-1 (Whisper V2) | 减少约 89-90% |
| 相比之前的 gpt-4o-transcribe | 减少约 70% |

#### 多语言表现

gpt-4o-mini-transcribe-2025-12-15 在以下语言表现特别突出：
- **中文（普通话）** -- 对本项目尤为重要
- 日语
- 印地语
- 孟加拉语
- 印尼语
- 意大利语

#### 社区反馈注意事项

早期版本的 gpt-4o-transcribe 存在以下问题（可能已在新快照中改善）：
- 短音频片段可能丢词（尤其是开头/结尾）
- 延迟较 whisper-1 高（whisper-1: ~857ms vs gpt-4o-transcribe: ~1598ms）
- 非正式对话中含糊语音处理不佳
- 部分场景下大量转录内容丢失

### 4. 定价对比

#### 按分钟计费（推荐）

| 模型 | 价格/分钟 | 价格/小时 | 价格/月（约33h） |
|------|----------|----------|---------------|
| `whisper-1` | $0.006 | $0.36 | $12.00 |
| `gpt-4o-transcribe` | $0.006 | $0.36 | $12.00 |
| `gpt-4o-transcribe-diarize` | $0.006 | $0.36 | $12.00 |
| `gpt-4o-mini-transcribe` | **$0.003** | **$0.18** | **$6.00** |

#### 按 Token 计费（仅 GPT-4o 模型，替代方式）

| 模型 | 音频输入 (per 1M tokens) | 文本输入 (per 1M tokens) | 文本输出 (per 1M tokens) |
|------|------------------------|------------------------|------------------------|
| `gpt-4o-transcribe` | $2.50 | $2.50 | $10.00 |
| `gpt-4o-mini-transcribe` | $1.25 | $1.25 | $5.00 |

> 注：对于标准转录场景，按分钟计费通常更划算。

### 5. 最新 API 变化

#### 2025-12 更新（最重要）

- 发布 `gpt-4o-mini-transcribe-2025-12-15` 新快照
- `gpt-4o-mini-transcribe` slug 已自动指向 2025-12-15 快照
- 旧快照 `gpt-4o-mini-transcribe-2025-03-20` 仍可使用
- 官方推荐从 gpt-4o-transcribe 切换至 gpt-4o-mini-transcribe

#### 2025-10 更新

- 发布 `gpt-4o-transcribe-diarize` 模型（说话人识别功能）
- 支持 `diarized_json` 响应格式
- 支持 `known_speaker_names[]` 和 `known_speaker_references[]` 参数
- 需要 `chunking_strategy`（音频 > 30s 时）

#### 2025-03 初始发布

- `gpt-4o-transcribe` 和 `gpt-4o-mini-transcribe` 首次发布
- Realtime API 新增 `intent=transcription` 转录专用模式

#### 翻译 API 状态

- `/v1/audio/translations` 仍然仅支持 `whisper-1`
- 没有迹象表明 OpenAI 计划为新模型添加翻译端点支持
- 需要翻译功能的应用应使用两步法（先转录再用 LLM 翻译）

### 6. 项目当前配置分析与更新建议

#### 当前配置

```swift
// EngineeringOptions.swift
static let whisperModel = "gpt-4o-transcribe"  // 云端转录模型

// Constants.swift
static let whisperTranscribeURL = "https://api.openai.com/v1/audio/transcriptions"
static let whisperTranslateURL = "https://api.openai.com/v1/audio/translations"
static let realtimeWebSocketURL = "wss://api.openai.com/v1/realtime?intent=transcription"

// ServiceCloudOpenAI.swift
// 翻译使用 whisper-1（正确，因为 translations API 仅支持此模型）
// 两步翻译法使用 gpt-4o-mini 做文本翻译（合理方案）
```

#### 分析结论

| 配置项 | 当前状态 | 评估 |
|-------|---------|------|
| API 端点 URL | 正确 | 无需更改 |
| 转录模型 (`gpt-4o-transcribe`) | 可用但非最优 | **建议更新** |
| 翻译用 `whisper-1` | 正确 | 翻译 API 仅支持此模型 |
| 两步翻译法 (`translationMethod = "two-step"`) | 最佳实践 | 推荐保持 |
| Realtime WebSocket URL | 正确 | 无需更改 |
| 音频格式支持 | 正确（m4a/wav） | 在 API 支持范围内 |

#### 具体更新建议

**建议 1：将转录模型切换为 `gpt-4o-mini-transcribe`**（推荐优先级：高）

```swift
// EngineeringOptions.swift
static let whisperModel = "gpt-4o-mini-transcribe"  // 原: "gpt-4o-transcribe"
```

理由：
- OpenAI 官方推荐 gpt-4o-mini-transcribe 优于 gpt-4o-transcribe
- 价格降低 50%（$0.003/min vs $0.006/min）
- 2025-12-15 快照幻觉率大幅降低（比 whisper-1 少 89%）
- 中文转录表现特别突出（项目主要使用场景）
- WER 比 whisper-1 低约 35%

**建议 2：注意 response_format 兼容性**（风险评估）

项目当前使用 `response_format=text`，这在 gpt-4o-mini-transcribe 上完全支持（支持 json 和 text）。无兼容性问题。

**建议 3：保持翻译策略不变**

当前的两步翻译法（`translationMethod = "two-step"`）是正确方案：
- 翻译 API 仍然仅支持 whisper-1，不如 gpt-4o 系列准确
- 先用高精度模型转录，再用 gpt-4o-mini 翻译，效果更好

**建议 4：监控 language 参数行为**（注意事项）

项目中 `sendRequest` 方法在 language 为空时默认使用 "zh"：
```swift
let effectiveLanguage = language.isEmpty ? "zh" : language
```
gpt-4o-mini-transcribe 支持 language 参数，但其自动语言检测能力更强。可考虑在未来测试移除默认 "zh" 回退，让模型自动检测语言，可能在多语言场景下表现更好。

**建议 5：关注 gpt-4o-transcribe-diarize**（未来功能）

如果项目将来需要会议录音等多人场景，gpt-4o-transcribe-diarize 提供内建的说话人识别功能，价格与 gpt-4o-transcribe 相同（$0.006/min）。当前项目为单人语音输入场景，暂不需要。

## 来源 (Sources)

- [Speech to text - OpenAI API Guide](https://platform.openai.com/docs/guides/speech-to-text) -- 官方语音转文字指南，模型对比和参数说明
- [GPT-4o Transcribe Model - OpenAI API](https://developers.openai.com/api/docs/models/gpt-4o-transcribe) -- gpt-4o-transcribe 模型详情页
- [GPT-4o mini Transcribe Model - OpenAI API](https://platform.openai.com/docs/models/gpt-4o-mini-transcribe) -- gpt-4o-mini-transcribe 模型详情页
- [Introducing next-generation audio models in the API - OpenAI](https://openai.com/index/introducing-our-next-generation-audio-models/) -- 新一代音频模型发布公告，包含 WER 基准
- [Updates for developers building with voice - OpenAI Developers](https://developers.openai.com/blog/updates-audio-models) -- 2025-12-15 快照更新公告，幻觉减少和精度提升数据
- [OpenAI Transcribe & Whisper API Pricing](https://costgoat.com/pricing/openai-transcription) -- 各模型定价对比汇总
- [Create translation - OpenAI API Reference](https://developers.openai.com/api/reference/resources/audio/subresources/translations/methods/create) -- 翻译 API 参考，确认仅支持 whisper-1
- [GPT-4o Transcribe Diarize - OpenAI Community](https://community.openai.com/t/introducing-gpt-4o-transcribe-diarize-now-available-in-the-audio-api/1362933) -- 说话人识别模型社区公告
- [gpt-4o-transcribe not as good as whisper - OpenAI Community](https://community.openai.com/t/gpt-4o-mini-transcribe-and-gpt-4o-transcribe-not-as-good-as-whisper/1153905) -- 社区对早期版本质量问题的反馈
- [OpenAI launches GPT-4o-transcribe - ScribeWave](https://scribewave.com/blog/openai-launches-gpt-4o-transcribe-a-powerful-yet-limited-transcription-model) -- 第三方分析 gpt-4o-transcribe 的局限性
- [Realtime transcription - OpenAI API](https://platform.openai.com/docs/guides/realtime-transcription) -- Realtime API 转录模式文档
