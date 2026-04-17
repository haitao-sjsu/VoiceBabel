# Deepgram 语音识别 API 调研

**日期**: 2026-04-14
**背景**: WhisperUtil macOS 语音转文字工具，评估是否集成 Deepgram 作为第三方云端引擎
**竞品参考**: VoiceInk 已集成 Deepgram

---

## Part 1: 公司和产品概述

### 公司背景

- **成立**: 2015 年，创始人 Scott Stephenson、Adam Sypniewski、Noah Shutty（均为密歇根大学物理学背景）
- **加速器**: Y Combinator Winter 2016
- **估值**: 2026 年 1 月 Series C 融资 $130M，估值 $1.3B（独角兽）
- **投资方**: AVP 领投，Alkeon、In-Q-Tel、Madrona、Tiger、Wing、YC、BlackRock 等跟投
- **营收**: 2024 年 $21.8M（同比增长 112%，2023 年为 $10.3M），2025 年现金流转正
- **规模**: ~164 人团队，200,000+ 开发者用户
- **客户**: NASA、Spotify、Twilio、Citibank 等 1,300+ 企业

### 核心产品线

| 产品 | 功能 | 说明 |
|------|------|------|
| **Listen** (STT) | 语音转文字 | Nova 系列模型，流式 + 批量 |
| **Speak** (TTS) | 文字转语音 | Aura 系列模型 |
| **Voice Agent API** | 语音智能体 | STT + LLM + TTS 一体化，$4.50/小时 |
| **Audio Intelligence** | 音频分析 | 摘要、情感分析、主题检测、意图识别 |

---

## Part 2: 语音识别模型对比

### 模型矩阵

| 模型 | 定位 | 关键特性 | 流式价格 ($/min) |
|------|------|----------|-----------------|
| **Flux** | 对话式 | 轮次检测，专为 Voice Agent 优化 | $0.0077 |
| **Nova-3 Monolingual** | 旗舰单语 | 最高精度，Keyterm Prompting | $0.0077 |
| **Nova-3 Multilingual** | 旗舰多语 | 10 语言 code-switching | $0.0092 |
| **Nova-2** | 上一代 | 高性价比，快速启动 | $0.0058 |
| **Nova-1** | 过时 | 兼容保留 | $0.0058 |
| **Enhanced** | 传统增强 | 早期模型 | $0.0165 |
| **Base** | 基础 | 早期模型 | $0.0145 |

### Nova-3 vs Nova-2 关键对比

| 维度 | Nova-3 | Nova-2 |
|------|--------|--------|
| 流式 WER (中位数) | 6.84% | ~8.4% |
| 批量 WER (中位数) | 5.26% | ~8.4% |
| 竞品优势幅度 | 54.2% | 11% |
| Code-switching | 10 语言实时切换 | 仅 西班牙语+英语 |
| Keyterm Prompting | 支持 (最多 100 词) | 不支持 |
| PII 实时脱敏 | 50 种实体类型 | 有限支持 |
| 延迟 | < 300ms | < 300ms |
| 批量推理速度 | 快 | 29.8 s/hr（含说话人分离） |
| 容器启动 | 标准 | 快 ~25%（模型更小） |

### Nova-3 技术架构

- **统一多语言架构**: 非级联语言特定模型，而是单一模型处理多语言
- **音频嵌入框架**: 表征学习，将音频压缩到表达性潜在空间
- **多阶段训练**: 大规模合成 code-switching 数据 + 精选真实数据
- **上下文学习机制**: 受 LLM 启发，支持动态词汇适应

---

## Part 3: 多语种混杂 (Code-Switching) 支持

### 核心发现：中英混杂不在官方支持列表

**Nova-3 Multilingual code-switching 支持的 10 种语言**:
English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese, Italian, Dutch

**中文（普通话）不在 code-switching 列表中。**

### 中文支持现状

- **单语转录**: Nova-3 支持 `zh`, `zh-CN`, `zh-TW`, `zh-Hant`, `zh-HK`（粤语）
- **Code-switching**: 中英混杂语音 **不被官方支持**
- **已知问题**: GitHub Discussion #761 有用户反馈多语言录音中仅英语部分被转录

### 使用方式

```
# 单语中文
language=zh&model=nova-3

# 多语 code-switching（不含中文）
language=multi&model=nova-3
```

### 对 WhisperUtil 的影响

这是一个 **关键限制**。WhisperUtil 的主要使用场景是中英混杂语音输入。如果 Deepgram 的 multilingual 模式不支持中文 code-switching，其实用价值会大打折扣。

对比 OpenAI：
- **gpt-4o-transcribe**: 天然支持中英混杂，无需特别配置
- **Whisper**: 通过 `language=zh` 可以较好处理中英混杂
- **Deepgram Nova-3**: 中文单语可用，但中英混杂场景缺失

---

## Part 4: 流式 (Streaming) vs 批量 (Batch) 转录

### 流式转录 (WebSocket)

- **协议**: WebSocket (`wss://api.deepgram.com/v1/listen`)
- **延迟**: < 300ms 端到端
- **机制**: 全双工通信，100-200ms 音频块逐块处理
- **实时结果**: interim_results 参数启用持续更新
- **事件类型**:
  - `ListenV1Results` — 转录结果（含置信度 + 词级时间戳）
  - `ListenV1Metadata` — 会话元数据
  - `ListenV1UtteranceEnd` — 语句结束标记
  - `ListenV1SpeechStarted` — 语音活动开始

### 批量转录 (REST)

- **端点**: `POST https://api.deepgram.com/v1/listen`
- **速度**: 约 120x 实时速度（30 分钟文件约 15 秒处理完）
- **输入**: URL 引用或直接上传音频文件
- **适用**: 会议录音、播客、客服电话等后处理场景

### 关键差异

| 维度 | 流式 | 批量 |
|------|------|------|
| 延迟 | < 300ms | 1-2x 实时时长 |
| 精度 | WER 6.84% (Nova-3) | WER 5.26% (Nova-3) |
| 价格 | 标准价 | 标准价（同价） |
| 协议 | WebSocket | REST (HTTP POST) |
| 适用场景 | 实时输入、语音代理 | 录音后处理 |

注意：Deepgram 的流式和批量价格相同（不像某些文章提到的 79% 差价，那是旧信息或针对旧模型）。Nova-3 的流式和预录制价格统一为 $0.0077/min。

---

## Part 5: 收费详情

### 免费额度

- **$200 免费信用**，无需信用卡，永不过期
- 按 Nova-3 $0.0077/min 计算 ≈ **25,974 分钟（433 小时）**
- 这是非常慷慨的免费额度（对比 OpenAI 无免费语音额度）

### 按量计费 (Pay As You Go)

| 模型 | 流式 ($/min) | 预录 ($/min) | 每小时 ($) |
|------|-------------|-------------|-----------|
| Flux | $0.0077 | $0.0077 | $0.462 |
| Nova-3 单语 | $0.0077 | $0.0077 | $0.462 |
| Nova-3 多语 | $0.0092 | $0.0092 | $0.552 |
| Nova-1/2 | $0.0058 | $0.0058 | $0.348 |
| Enhanced | $0.0165 | $0.0165 | $0.990 |
| Base | $0.0145 | $0.0145 | $0.870 |

### Growth 计划 (预付年费 $4,000+，约 -20%)

| 模型 | 流式 ($/min) | 预录 ($/min) |
|------|-------------|-------------|
| Flux | $0.0065 | $0.0065 |
| Nova-3 单语 | $0.0065 | $0.0065 |
| Nova-3 多语 | $0.0078 | $0.0078 |
| Nova-1/2 | $0.0047 | $0.0047 |

### 附加功能费用 (Pay As You Go / Growth)

| 功能 | $/min |
|------|-------|
| PII 脱敏 (Redaction) | $0.0020 / $0.0017 |
| Keyterm Prompting | $0.0013 / $0.0012 |
| 说话人分离 (Diarization) | $0.0020 / $0.0017 |
| Smart Formatting | 免费包含 |
| 标点 (Punctuation) | 免费包含 |

### 与 OpenAI 价格对比

| 服务 | 价格 ($/min) | 每 1000 分钟 ($) |
|------|-------------|-----------------|
| Deepgram Nova-3 | $0.0077 | $7.70 |
| Deepgram Nova-2 | $0.0058 | $5.80 |
| OpenAI Whisper | $0.006 | $6.00 |
| OpenAI gpt-4o-transcribe | $0.006 | $6.00 |
| Google Chirp 2 | $0.016 | $16.00 |
| Google Chirp 2 (>2M min/月) | $0.004 | $4.00 |

**结论**: Nova-3 比 OpenAI 贵约 28%，但 Nova-2 比 OpenAI 便宜约 3%。考虑到 Deepgram 的速度优势，性价比因场景而异。

---

## Part 6: API 特性

### 核心转录特性

| 特性 | 参数 | 说明 |
|------|------|------|
| 自动标点 | `punctuate=true` | 自动添加标点和大写 |
| Smart Formatting | `smart_format=true` | 统一标点+ITN+说话人分离 |
| 说话人分离 | `diarize=true` | 多人说话识别（付费） |
| 多通道 | `multichannel=true` | 独立处理每个音频通道 |
| 数字格式化 | `numerals=true` | 将口述数字转为阿拉伯数字 |
| 亵渎过滤 | `profanity_filter=true` | 过滤脏话 |
| 语言检测 | `detect_language=true` | 自动识别语言 |

### 高级特性

| 特性 | 参数 | 说明 |
|------|------|------|
| Keyterm Prompting | `keywords=term:boost` | 提升专有名词识别率 (最多100词，6x提升) |
| PII 脱敏 | `redact=pci,ssn,...` | 实时移除敏感信息 (50种实体) |
| 实体检测 | `detect_entities=true` | 提取姓名、电话、邮件等 |
| Utterance 分割 | `utterances=true` | 按语句分段 |
| 端点检测 | `endpointing=100` | 流式模式下的语句结束检测 (ms) |
| 回调 | `callback=url` | 异步处理完成后回调 |

### 语音活动检测 (VAD)

- `ListenV1SpeechStarted` 事件：检测到语音开始
- `ListenV1UtteranceEnd` 事件：语句结束
- `endpointing` 参数控制静音阈值

---

## Part 7: SDK 和集成方式

### 官方 SDK

| 语言 | 状态 | 仓库 |
|------|------|------|
| Python | GA (v6) | deepgram/deepgram-python-sdk |
| JavaScript/TypeScript | GA (v5) | deepgram/deepgram-js-sdk |
| Go | GA | deepgram/deepgram-go-sdk |
| .NET | GA | deepgram/deepgram-dotnet-sdk |
| Java | 开发中 | — |
| **Swift** | **无官方 SDK** | — |

### 对 WhisperUtil 的集成影响

**无官方 Swift SDK**，需要自行实现：

#### REST API 集成（批量模式）

```swift
// POST https://api.deepgram.com/v1/listen
// Headers: Authorization: Token <API_KEY>
//          Content-Type: audio/wav (或其他格式)
// Query: model=nova-3&language=zh&smart_format=true&punctuate=true
```

#### WebSocket 集成（流式模式）

```swift
// wss://api.deepgram.com/v1/listen?model=nova-3&language=zh&encoding=linear16&sample_rate=16000
// 认证方式 1: Authorization header (macOS URLSessionWebSocketTask 支持)
// 认证方式 2: Sec-WebSocket-Protocol: token, <API_KEY>
```

#### 集成工作量评估

- **REST (批量)**: 简单，与现有 ServiceCloudOpenAI 结构类似，约 1-2 天
- **WebSocket (流式)**: 中等，与现有 ServiceRealtimeOpenAI 结构类似，约 2-3 天
- **共用架构**: 可复用现有 AudioRecorder/AudioEncoder，仅需新建 Service 层

### 参考实现

Deepgram 官方有一个 iOS 示例项目 `deepgram-devs/deepgram-live-transcripts-ios`，可参考其 WebSocket 连接和音频流处理方式。

---

## Part 8: 准确率和延迟对比

### 第三方基准测试 (Artificial Analysis, Common Voice v16.1)

| 模型 | Raw WER | 处理速度 (audio sec/sec) | 价格 ($/1000min) |
|------|---------|------------------------|-----------------|
| Deepgram Nova-3 | 12.8% | 157.5x | $4.30 |
| OpenAI GPT-4o Transcribe | 8.9% | 38.6x | $6.00 |
| OpenAI Whisper Large v2 | 10.6% | 34.3x | $6.00 |
| Google Chirp 2 | 9.8% | 68.7x | $16.00 |

### Voicewriter.io 基准测试 (自定义数据集)

**批量 Raw WER**:
| 模型 | WER |
|------|-----|
| OpenAI GPT-4o Transcribe | 5.6% |
| Google Gemini 1.5 Pro | 6.5% |
| Deepgram Nova-3 | 7.6% |
| OpenAI Whisper Large v2 | 7.2% |

**流式 Raw WER**:
| 模型 | WER |
|------|-----|
| Deepgram Nova-3 | 9.7% |
| OpenAI Whisper Large v2 | 12.4% |

### Deepgram 官方基准 (81.69 小时，9 领域)

| 模式 | Deepgram Nova-3 WER | 最佳竞品 WER |
|------|---------------------|-------------|
| 流式 | 6.84% | 14.92% |
| 批量 | 5.26% | 10.0% |

### 综合分析

| 维度 | Deepgram Nova-3 | OpenAI GPT-4o Transcribe |
|------|-----------------|--------------------------|
| 英语精度 (批量) | 良好 (7.6-12.8%) | 最佳 (5.6-8.9%) |
| 英语精度 (流式) | 最佳 (6.84-9.7%) | 不原生支持流式 |
| 处理速度 | 极快 (157.5x) | 中等 (38.6x) |
| 延迟 (流式) | < 300ms | N/A (需分块处理，秒级) |
| 中文精度 | 一般 | 优秀 |
| 中英混杂 | 不支持 | 天然支持 |
| 价格 | $0.0077/min | $0.006/min |

**关键洞察**: Deepgram 在英语流式场景有明显优势（速度快 4x，流式 WER 更低），但在中文和多语种混杂场景不如 OpenAI。第三方基准（非 Deepgram 自测）显示其批量英语精度略逊于 GPT-4o-transcribe。

---

## Part 9: 企业级特性

### 合规认证

| 认证 | 状态 |
|------|------|
| SOC 2 Type II | 已通过 (Cyberguard Compliance 审计，无例外项) |
| HIPAA | 支持 (提供 BAA) |
| PCI DSS | 已认证 |
| GDPR | 合规 |
| CCPA | 合规 |

### 安全措施

- **传输加密**: TLS 1.3
- **静态加密**: AES-256
- **访问控制**: RBAC (基于角色的访问控制)
- **MFA**: 强制多因素认证
- **数据保留**: 默认零保留 (zero-retention)，可配置
- **PII 脱敏**: 实时，50 种实体类型
- **区域处理**: 可选数据处理区域

### 企业计划

- 自定义 SLA
- 专属支持
- 自定义模型训练
- 本地部署选项 (on-premise)
- 安全报告可联系 security@deepgram.com 获取

---

## Part 10: 已知问题和局限性

### 关键限制

1. **中英 code-switching 不支持**: multilingual 模式仅覆盖 10 种语言，不含中文。对 WhisperUtil 用户场景是致命短板
2. **中文转录精度一般**: 相比英语，中文（尤其是口语化、带口音的）精度有明显差距
3. **无 Swift SDK**: 需自行实现 REST 和 WebSocket 客户端
4. **批量精度不是最优**: 第三方测试中，批量 WER 不如 GPT-4o-transcribe

### 用户反馈的问题

- 多语言录音中有时仅转录英语部分（GitHub Discussion #761）
- 说话人分离偶有错误，文本重复
- 西班牙语、智利口音等非标准口音精度较差
- Voice Agent API 使用特定 LLM 时有间歇性高延迟和错误率
- WebSocket 连接偶尔因冗余被释放
- 对于初创企业，规模化成本难以预测

### 与 OpenAI API 的可靠性对比

Deepgram 作为独立公司，其 API 可用性和稳定性历史记录可在 status.deepgram.com 查看。相较于 OpenAI 偶尔的 API 过载问题，Deepgram 作为专注语音的公司，在语音 API 稳定性上有一定优势。

---

## Part 11: 补充：跨语言对 Code-Switching 评测数据

### 各服务多语言对 CS 支持矩阵

| 服务 | 支持的 CS 语言对 | 日+英 | 中+日 | 西+英 | 韩+英 | 印地+英 |
|------|-----------------|:-----:|:-----:|:-----:|:-----:|:------:|
| **Deepgram Nova-3** | **en/es/fr/de/hi/ru/pt/ja/it/nl 共10语互切** | **✅** | **❌** | **✅** | **❌** | **✅** |
| Speechmatics | 专门双语包：cmn+en, ar+en, ms+en, ta+en, fil+en | ❌ | ❌ | ⚠️ 需特殊配置 | ❌ | ❌ |
| Soniox | 宣称 60+ 语言统一模型自动检测 | ❓ 无专项数据 | ❓ | ❓ | ❓ | ❓ |
| Whisper/gpt-4o-transcribe | 理论99语言，无专门CS优化 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| ElevenLabs | 仅优化印度语-英语 | ❌ | ❌ | ❌ | ❌ | ⚠️ |
| Mistral Voxtral | 声称13语言切换，无专项数据 | ❓ | ❓ | ❓ | ❓ | ❓ |
| Apple SFSpeechRecognizer | 单语言，不支持CS | ❌ | ❌ | ❌ | ❌ | ❌ |
| Groq (Whisper) | 同 Whisper 模型 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |

**结论：没有一个服务能覆盖所有语言对的 code-switching。** Deepgram Nova-3 在日+英、西+英、印地+英三个语言对上有明确支持，但中文相关的 CS 场景仍然缺失。

### Code-Switching 专用评测数据集

| 数据集 | 语言对 | 规模 | 说明 |
|--------|--------|------|------|
| ASCEND | 中-英 | 10.62h, 23人 | 香港自发对话 |
| SEAME | 中-英 / 马来-英 | ~30h, 92人 | 新加坡/马来西亚，MER 最佳 ~14.2% |
| CS-FLEURS (Interspeech 2025) | 52 语言, 113 对 | 三子集 | 目前最大规模多语 CS 基准 |
| SwitchLingua (NeurIPS 2025) | 12 语言, 63 民族 | 420K 文本 + 80h 音频 | 提出新指标 SAER |
| Miami Bangor | 西-英 | ~35h | 迈阿密西英双语对话 |
| CS-Dialogue | 中-英 | 104h | 2025年新发布，自发对话 |

### Whisper 各语言对 CS 实测表现

- **中英**：MER 约 14-20%（SEAME），经常把整句识别为单一语言
- **韩英**：微调后 CER 可降 1.7%，基线较差
- **日英**：无专项公开数据
- **西英**：西语单语好，但 CS 场景缺评测
- **gpt-4o-transcribe vs Whisper v3**：OpenAI 称改善但无具体数据

> 对 Deepgram 而言，其 Nova-3 Multilingual 的 10 语言 CS 覆盖了日英、西英、印地英，但 **中英、韩英不在列表中**。如果 Deepgram 能将中文纳入 CS 支持列表，将大幅提升对 WhisperUtil 用户群的吸引力。

### 学术界核心趋势

- 参数高效微调(LoRA/Adapter) + 语言识别引导解码 + 合成数据增强是三大主线
- 微调后 MER 可相对降 4-7%

---

## 结论：是否值得为 WhisperUtil 集成 Deepgram？

### 优势

- $200 免费额度极其慷慨（433 小时）
- 英语流式转录速度和精度业界领先
- WebSocket API 设计与现有 ServiceRealtimeOpenAI 架构相似，集成成本可控
- 企业级安全合规

### 劣势

- **中英混杂 (code-switching) 不支持** — 这是 WhisperUtil 的核心使用场景
- 中文单语精度不如 OpenAI
- 无官方 Swift SDK
- Nova-3 价格略高于 OpenAI ($0.0077 vs $0.006/min)

### 建议

**短期不建议集成**。Deepgram 的核心优势在英语流式场景，而 WhisperUtil 的核心需求是中英混杂语音输入。在 Deepgram 将中文纳入 code-switching 支持列表之前，集成价值有限。

**持续关注**。Deepgram 正在积极扩展 Nova-3 的语言支持（2025-2026 年已多次新增语言），中文 code-switching 可能在未来版本中加入。建议：
- 关注 Deepgram Changelog (developers.deepgram.com/changelog)
- 当中文 code-switching 上线时重新评估
- 如未来需要纯英语用户市场，可优先集成 Deepgram

**如果仍想集成（作为可选引擎）**: 预计 3-5 天工作量，新增 `ServiceDeepgramCloud` (REST) 和 `ServiceDeepgramRealtime` (WebSocket) 两个 Service，复用现有音频管道。
