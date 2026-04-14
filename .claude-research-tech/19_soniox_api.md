# Soniox 语音识别 API 调研

日期：2026-04-14

## 摘要

Soniox 是一家专注于实时语音 AI 的公司，提供覆盖 60+ 语言的语音转文字和翻译 API。其核心卖点包括：单一统一模型处理所有语言（无需切换模型）、原生多语种混杂（code-switching）支持、低延迟实时流式转录、以及极具竞争力的价格（实时约 $0.12/小时，异步约 $0.10/小时，远低于 OpenAI）。最新的 v4 模型（2026 年 1-2 月发布）宣称在 60+ 语言上达到"人类水平"准确率。中文识别 WER 6.6%，中英混杂可自然识别。对 WhisperUtil 而言，Soniox 在价格、多语种混杂、中文准确率方面有明显优势，但缺乏原生 Swift/macOS SDK，需通过 WebSocket 直接集成。目前新注册已无免费额度。

---

## Part 1：公司和产品概述

### 1.1 公司背景

Soniox 是一家专注于语音 AI 的技术公司，产品定位为"实时语音 AI 平台"（Real-time Voice AI Platform）。主要面向两类用户：

- **Soniox App**：面向个人和团队的语音工作空间应用（会议转录、笔记等）
- **Speech-to-Text API**：面向开发者和企业的语音识别 API

### 1.2 核心定位与特色

- **单一统一模型**：一个模型处理 60+ 语言，无需为不同语言加载/切换模型
- **原生 code-switching**：模型架构原生支持多语种混杂，无需预先指定语言
- **实时 + 异步双模式**：WebSocket 实时流式转录 + REST API 异步文件转录
- **一体化 API**：转录、翻译、说话人分离、时间戳在一次 API 调用中完成
- **企业级合规**：SOC 2 Type II、HIPAA 认证，支持 Sovereign Cloud（美国、欧盟、日本等区域部署）

### 1.3 时间线（近期）

| 时间 | 事件 |
|------|------|
| 2025-05 | 推出 Soniox App |
| 2025-10 | 取消新注册免费额度（因滥用） |
| 2025-11 | Sovereign Cloud 上线 |
| 2026-01-29 | 发布 Soniox v4 Async 模型 |
| 2026-02-05 | 发布 Soniox v4 Real-Time 模型 |
| 2026-02-28 | v3 模型自动路由至 v4 |

---

## Part 2：语音识别模型

### 2.1 当前模型列表

| 模型 | 类型 | 发布日期 | 状态 |
|------|------|----------|------|
| `stt-rt-v4` | 实时流式 | 2026-02-05 | 当前最新 |
| `stt-async-v4` | 异步文件 | 2026-01-29 | 当前最新 |
| `stt-rt-v3` | 实时流式 | 更早 | 已自动路由至 v4 |
| `stt-async-v3` | 异步文件 | 更早 | 已自动路由至 v4 |

### 2.2 v4 模型架构与能力

**架构**：
- 基于 Transformer，具有深度注意力机制（deep attention mechanisms）
- 上下文窗口最大 8,000 tokens
- 上下文整合发生在识别过程中（而非后处理）

**核心能力**：
- 60+ 语言原生支持，无需预先指定语言
- 单次请求最长 5 小时音频
- 同步输出转录 + 翻译
- 说话人分离（diarization）
- 置信度评分（0.0-1.0）
- 字级别时间戳
- 域适配上下文（context customization）

### 2.3 v4 Real-Time 特有功能

- **语义端点检测**（Semantic Endpointing）：基于语义理解而非单纯静音检测来判断说话结束，减少误截断（如念电话号码时的停顿不会被误判为说话结束）
- **`max_endpoint_delay_ms` 参数**：控制端点响应延迟
- **手动终结**（Manual Finalization）：可手动触发，毫秒级返回高准确率最终转录
- 连续流式转录最长 5 小时

### 2.4 v4 Async 特有功能

- 宣称达到"人类水平"（human-parity）转录质量
- 改进的说话人分离
- 增强的翻译质量

---

## Part 3：多语种混杂（Code-Switching）支持

**这是 Soniox 与 WhisperUtil 最相关的核心优势之一。**

### 3.1 工作原理

Soniox 的单一统一模型架构天然支持 code-switching：
- 模型原生理解所有 60+ 语言，不需要在语言之间切换
- 可以在一句话中间切换语言，无需用户预先指定
- 自动语言识别（Language Identification）内置于模型中

### 3.2 中英混杂支持

Soniox 官方明确展示了中英混杂的支持能力。官方示例：

> "群里那个milk tea的deal快没了，deadline是12:30，你要不要一起拼单？"

这种句中混合中英文的场景可以被自然识别，无需特殊配置。

### 3.3 其他混杂组合

官方提到支持的混杂场景包括：
- 中英混杂（Chinese-English）
- Hindi-English（Hinglish）—— 官方引用用户评价："It's the first model we've used that actually understands Hinglish. Switching mid-sentence just works."
- Spanish-English
- 理论上 60+ 语言的任意组合

### 3.4 与竞品对比

对于中英混杂场景，这是 Soniox 相对于 OpenAI Whisper/gpt-4o-transcribe 的显著优势。OpenAI 的模型虽然也是多语言的，但在 code-switching 场景下表现不如 Soniox 稳定。

---

## Part 4：流式（Streaming）能力和延迟

### 4.1 实时转录架构

- 基于 **WebSocket** 持久连接
- 端点：`wss://stt-rt.soniox.com/transcribe-websocket`
- 逐 token 流式返回（非整句）
- 每个 token 带 `is_final` 标记：`false` = 临时结果（可能变化），`true` = 最终确认结果

### 4.2 延迟表现

- 官方宣称"毫秒级"最终转录延迟
- 专门解决对话 AI 中常见的 500ms 延迟问题
- Manual Finalization 可在毫秒内返回高准确率最终结果
- 语义端点检测减少不必要的等待

### 4.3 流式会话限制

- 单次 WebSocket 连接最长 **300 分钟**（5 小时）音频
- 支持音频格式自动检测（`"auto"`）
- 支持 PCM（需指定通道数和采样率）、WAV、OGG、FLAC

### 4.4 对 WhisperUtil 的意义

当前 WhisperUtil 的 Realtime 模式使用 OpenAI Realtime API（WebSocket），单次会话限制 60 分钟。Soniox 的 5 小时限制是显著优势。延迟表现需要实测对比。

---

## Part 5：收费情况

### 5.1 计费模型

**按 token 计费**（非按时长），但官方提供了等效时长价格：

| 计费项 | 异步（文件） | 实时（流式） |
|--------|-------------|-------------|
| 输入音频 token | $1.50 / 百万 token | $2.00 / 百万 token |
| 输入文本 token | $3.50 / 百万 token | $4.00 / 百万 token |
| 输出文本 token | $3.50 / 百万 token | $4.00 / 百万 token |
| **等效时长价格** | **~$0.10/小时** | **~$0.12/小时** |

### 5.2 Token 换算参考

- 1 小时音频 ≈ 30,000 输入音频 token
- 1 小时语音 ≈ 15,000 输出文本 token
- 1 个输出字符 ≈ 0.3 token

### 5.3 免费额度

- **之前**：新注册赠送 $200 免费额度（约 2,000 小时转录）
- **现在（2025-10 起）**：新注册不再赠送免费额度（因大量滥用/垃圾注册）
- 已有合法用户保留现有额度
- 新开发者只能使用按量付费（pay-as-you-go）

### 5.4 与 OpenAI 价格对比

| 服务 | 每小时价格 |
|------|-----------|
| Soniox 异步 | ~$0.10 |
| Soniox 实时 | ~$0.12 |
| OpenAI mini-transcribe | $0.18 |
| OpenAI 4o-transcribe | $0.36 |
| OpenAI Realtime API | $0.38-$1.15 |

**结论**：Soniox 比 OpenAI 便宜 2-10 倍。对于 WhisperUtil 的实时转录场景，Soniox ($0.12/h) vs OpenAI Realtime API ($0.38-$1.15/h)，成本优势极为显著。

---

## Part 6：API 特性详解

### 6.1 说话人分离（Speaker Diarization）

- 实时和异步模式均支持
- 跨 60+ 语言工作
- 多说话人快速对话和重叠语音场景下仍可工作
- 在 WebSocket 响应的每个 token 中携带 speaker label

### 6.2 实时翻译

- 支持 3,600+ 语言对（60+ 语言的任意组合）
- 单向和双向翻译均支持
- 与转录同步进行，无需额外 API 调用
- 连续翻译（不等整句结束就开始翻译）

### 6.3 域适配上下文（Context Customization）

- 可提供领域、话题、参与者姓名等信息
- 提升专业术语识别准确率（医疗、法律、金融等）
- 上下文在识别过程中整合（非后处理纠正）
- 无需重新训练模型

### 6.4 字母数字识别

- 准确捕获电话号码、身份证号、车牌号等
- 对中文场景中穿插的数字/字母序列有增强支持

### 6.5 语言识别（Language Identification）

- 自动检测说话语言
- 可提供 language hint 辅助
- 支持句中切换语言的识别

### 6.6 时间戳与置信度

- 每个 token 带起止时间戳（毫秒）
- 每个 token 带置信度评分（0.0-1.0）

---

## Part 7：集成方式

### 7.1 API 接口

| 接口 | 用途 | 地址 |
|------|------|------|
| WebSocket API | 实时流式转录 | `wss://stt-rt.soniox.com/transcribe-websocket` |
| REST API | 异步文件转录 | `https://api.soniox.com/v1` |

### 7.2 REST API 端点

- **Auth API**：生成临时 API Key
- **Files API**：音频文件上传/管理
- **Models API**：获取可用模型列表
- **Transcriptions API**：创建/管理转录任务
- OpenAPI Schema：`https://api.soniox.com/v1/openapi.json`

### 7.3 WebSocket 连接流程

1. 建立 WebSocket 连接到 `wss://stt-rt.soniox.com/transcribe-websocket`
2. 发送 JSON 配置消息（含 API Key、模型、音频格式、语言设置等）
3. 流式发送二进制音频帧
4. 接收 JSON 响应（含 token 数组、时间戳、置信度、说话人标签）
5. 发送空帧触发连接关闭，收到 finished 响应后断开

### 7.4 认证方式

- 标准 API Key（通过控制台生成）
- 临时 API Key（推荐用于客户端应用，自动过期）
- 环境变量：`SONIOX_API_KEY`

### 7.5 官方 SDK

| SDK | 语言/平台 |
|-----|----------|
| Python SDK | Python（sync + async 客户端） |
| Node SDK | Node.js |
| Web SDK | 浏览器 JavaScript |
| React SDK | React |
| React Native SDK | React Native（iOS/Android） |

**注意：无原生 Swift/macOS SDK。** WhisperUtil 需要直接通过 WebSocket API 集成，类似于当前 OpenAI Realtime API 的集成方式。

### 7.6 第三方集成

Soniox 支持与以下平台集成：LiveKit、Pipecat、Twilio、LangChain、Vercel AI SDK、n8n。

---

## Part 8：与竞品对比

### 8.1 准确率（WER）对比

基于 Soniox 2025 年 3 月基准测试（60 种语言，使用真实 YouTube 音频）：

**英文 WER**：
| 服务 | WER |
|------|-----|
| Soniox | 6.5% |
| OpenAI | 10.5% |

**中文 WER/CER**：
| 服务 | 错误率 |
|------|--------|
| Soniox | 6.6% |
| Azure | 10.1% |
| AWS | 16.8% |
| OpenAI | 18% |
| Google | 54.1% |
| Deepgram | 94.4% |

> 注意：以上数据来自 Soniox 自己的基准测试，可能存在偏向性。但测试方法（真实 YouTube 音频、人工标注 ground truth、标准化评估）相对可信。

### 8.2 功能对比（Soniox vs OpenAI）

| 功能 | Soniox | OpenAI |
|------|--------|--------|
| 单一多语言模型 | ✅ | ✅ |
| Language hint | ✅ | ❌ |
| 语言自动识别 | ✅ | ❌ |
| 说话人分离 | ✅ | ❌ |
| 域适配上下文 | ✅ | ✅（有限） |
| 时间戳 | ✅ | ❌（Realtime API） |
| 置信度评分 | ✅ | ✅ |
| 单向翻译 | ✅ | ✅（仅翻译为英文） |
| 双向翻译 | ✅ | ❌ |
| 端点检测 | ✅（语义级） | ✅（VAD） |
| Manual Finalization | ✅ | ❌ |
| Sovereign Cloud | ✅ | ⚠️（有限） |

### 8.3 价格对比

Soniox 实时转录比 OpenAI Realtime API 便宜约 3-10 倍，比 OpenAI 4o-transcribe 便宜约 3 倍。

### 8.4 综合评估

| 维度 | Soniox 优势 | Soniox 劣势 |
|------|------------|------------|
| 准确率 | 中文、英文均领先 | 基准测试为自测，需独立验证 |
| 价格 | 显著便宜 | 无免费额度供评估 |
| Code-switching | 核心优势，原生支持 | — |
| 功能丰富度 | 一体化 API（转录+翻译+分离） | — |
| SDK | — | 无 Swift/macOS 原生 SDK |
| 生态 | — | 社区规模远小于 OpenAI |

---

## Part 9：已知问题和局限性

### 9.1 无原生 Swift/macOS SDK

Soniox 目前仅提供 Python、Node、Web、React、React Native SDK。WhisperUtil 作为 macOS 原生 Swift 应用，需要自行实现 WebSocket 客户端。不过这与当前 OpenAI Realtime API 的集成方式类似（WhisperUtil 已有 WebSocket 集成经验），技术难度可控。

### 9.2 无免费额度

2025 年 10 月起，新注册用户不再获得免费额度。评估阶段需要付费测试。不过按量付费价格较低（$0.12/小时），少量测试成本可接受。

### 9.3 基准测试的客观性

所有公开基准测试数据均来自 Soniox 自己的测试。虽然测试方法（真实音频 + 人工标注）有一定可信度，但缺乏独立第三方验证。需要在实际使用场景中自行验证。

### 9.4 公司规模与生态

Soniox 是相对较小的公司，与 OpenAI、Google、Azure 等巨头相比：
- 社区支持和文档丰富度不及大厂
- 长期稳定性和服务连续性有一定风险
- 移动端应用有用户反馈支持响应慢的问题

### 9.5 中文方言支持不明确

官方提到支持"方言和口音"，但未明确列出具体支持哪些中文方言（如粤语、闽南语、四川话等）。主要针对普通话优化。

### 9.6 连接时长限制

WebSocket 单次连接最长 300 分钟（5 小时）。虽然远优于 OpenAI 的 60 分钟，但对超长会议场景仍需处理重连。

### 9.7 Token 计费的不透明性

按 token 而非按时长计费，token 与实际时长/字数的换算存在不确定性，实际账单可能与预估有差异。

---

## Part 10：对 WhisperUtil 集成的评估

### 10.1 集成可行性

| 方面 | 评估 |
|------|------|
| 技术可行性 | **高** — WebSocket API，与现有 Realtime API 集成方式类似 |
| 工作量 | **中等** — 需实现 Soniox WebSocket 协议（JSON 配置 + 二进制音频流），但可复用现有 WebSocket 和音频编码基础设施 |
| 音频格式 | **兼容** — 支持 PCM、WAV、OGG、FLAC，与现有 AudioRecorder/AudioEncoder 输出兼容 |

### 10.2 潜在收益

1. **中英混杂识别**：对中国用户日常场景（工作邮件口述、技术讨论等）极为实用
2. **成本大幅降低**：实时模式 $0.12/h vs OpenAI Realtime $0.38-$1.15/h
3. **中文准确率提升**：WER 6.6% vs OpenAI 18%（需实测验证）
4. **说话人分离**：WhisperUtil 目前不具备此功能，可作为差异化特性
5. **更长会话时长**：5 小时 vs OpenAI 60 分钟

### 10.3 集成建议

**推荐作为第四种 API 模式集成**，与现有 Local / Cloud / Realtime 并列：

```
Services/
  ServiceCloudOpenAI.swift      — 现有 Cloud 模式
  ServiceRealtimeOpenAI.swift   — 现有 Realtime 模式
  ServiceLocalWhisper.swift     — 现有 Local 模式
  ServiceRealtimeSoniox.swift   — 新增 Soniox 模式
```

集成优先级：**中高**。建议在完成当前核心功能稳定后，作为下一阶段增强功能考虑。

### 10.4 注意事项

- 需额外管理 Soniox API Key（Keychain 已有基础设施可复用）
- 需在设置 UI 中增加 Soniox 选项
- 需处理 Soniox 的 token 响应格式（`is_final` 标记）与现有文本输出管线的对接
- 翻译功能可直接使用 Soniox 内置翻译，无需额外调用 OpenAI Whisper 翻译 API

---

## Part 11: 补充：跨语言对 Code-Switching 评测数据

### 各服务多语言对 CS 支持矩阵

| 服务 | 支持的 CS 语言对 | 日+英 | 中+日 | 西+英 | 韩+英 | 印地+英 |
|------|-----------------|:-----:|:-----:|:-----:|:-----:|:------:|
| Deepgram Nova-3 | en/es/fr/de/hi/ru/pt/ja/it/nl 共10语互切 | ✅ | ❌ | ✅ | ❌ | ✅ |
| Speechmatics | 专门双语包：cmn+en, ar+en, ms+en, ta+en, fil+en | ❌ | ❌ | ⚠️ 需特殊配置 | ❌ | ❌ |
| **Soniox** | **宣称 60+ 语言统一模型自动检测** | **❓ 无专项数据** | **❓** | **❓** | **❓** | **❓** |
| Whisper/gpt-4o-transcribe | 理论99语言，无专门CS优化 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| ElevenLabs | 仅优化印度语-英语 | ❌ | ❌ | ❌ | ❌ | ⚠️ |
| Mistral Voxtral | 声称13语言切换，无专项数据 | ❓ | ❓ | ❓ | ❓ | ❓ |
| Apple SFSpeechRecognizer | 单语言，不支持CS | ❌ | ❌ | ❌ | ❌ | ❌ |
| Groq (Whisper) | 同 Whisper 模型 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |

**结论：没有一个服务能覆盖所有语言对的 code-switching。** Soniox 宣称 60+ 语言统一模型原生支持 CS，且官方有中英混杂示例，但缺乏独立第三方在标准 CS 数据集上的评测结果。其实际表现是否优于竞品，仍需在 SEAME、ASCEND 等标准数据集上验证。

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

> 对 Soniox 而言，其统一模型架构理论上最适合 CS 场景（无需切换模型/语言包），且已有中英混杂的官方示例。但目前 ❓ 标记说明缺乏在标准 CS 评测数据集上的独立验证。建议在集成评估时，使用 SEAME 或 ASCEND 的样本音频进行实测对比。

### 学术界核心趋势

- 参数高效微调(LoRA/Adapter) + 语言识别引导解码 + 合成数据增强是三大主线
- 微调后 MER 可相对降 4-7%

---

## 参考链接

- [Soniox 官网](https://soniox.com/)
- [Soniox 定价](https://soniox.com/pricing)
- [Soniox 文档](https://soniox.com/docs)
- [Soniox v4 Async 博客](https://soniox.com/blog/2026-01-29-soniox-v4-async)
- [Soniox v4 Real-Time 博客](https://soniox.com/blog/2026-02-05-soniox-v4-real-time)
- [Soniox vs OpenAI 对比](https://soniox.com/compare/soniox-vs-openai)
- [Soniox 中文语音识别](https://soniox.com/speech-to-text/chinese)
- [Soniox 基准测试](https://soniox.com/benchmarks)
- [Soniox WebSocket API 文档](https://soniox.com/docs/stt/api-reference/websocket-api)
- [Soniox 免费额度变更通知](https://soniox.com/blog/2025-10-27-free-credits-update-for-soniox-api)
- [Soniox Python SDK (GitHub)](https://github.com/soniox/soniox_python)
