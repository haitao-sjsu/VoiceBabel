# Speechmatics 语音识别 API 调研

> 调研日期：2026-04-14
> 调研目的：评估 Speechmatics 语音识别 API 是否值得集成到 WhisperUtil（macOS 语音转文字工具），重点关注多语种混杂（code-switching）、流式转录、定价

---

## 核心结论（先说重点）

**Speechmatics 是目前市场上 code-switching（多语种混杂）能力最强的商业语音识别 API 之一。** 它明确支持 Mandarin-English（`cmn_en`）双语转录，code-switching 错误率比最接近的竞品低 35%。对于中英混杂场景，这是一个非常有吸引力的选项。

**但集成成本较高：** 没有原生 Swift SDK，需要通过 WebSocket 自行对接；定价高于 OpenAI Whisper API（约 $0.24/hr vs $0.36/hr）；中国大陆无服务器节点，延迟可能较高。

**建议：** 作为 WhisperUtil 的可选高级后端值得考虑，尤其面向中英混杂场景的用户。但优先级低于当前已集成的 OpenAI 方案，可作为未来扩展。

---

## Part 1：公司与产品概述

### 1.1 公司背景

| 项目 | 信息 |
|------|------|
| 公司名 | Speechmatics |
| 成立年份 | 2006 |
| 总部 | 英国剑桥（Cambridge, UK） |
| 类型 | 私营 B2B SaaS |
| 定位 | 企业级语音 AI 平台 |
| 合规认证 | GDPR、HIPAA、SOC 2 |

Speechmatics 是一家英国老牌语音识别公司，源自剑桥大学的研究。公司专注于为企业提供高精度、多语种的语音识别技术，在欧洲市场有较强影响力。

### 1.2 产品线

- **Speech-to-Text（STT）**：核心产品，支持实时和批量转录，覆盖 55+ 语言
- **Text-to-Speech（TTS）**：合成语音，目前支持英语（美式和英式），其他语言开发中
- **Speech Intelligence**：摘要、情感分析、话题检测等上层能力
- **Translation**：语音转录 + 翻译一体化，支持 30+ 语言对英语的翻译

### 1.3 部署方式

| 部署模式 | 说明 |
|---------|------|
| Cloud API | SaaS，全球多区域可用 |
| On-Premises | 本地私有化部署，适合敏感数据 |
| On-Device | 端侧推理，离线可用 |
| Edge/Hybrid | 边缘低延迟部署 |

> 注意：中国大陆没有服务器节点，对实时转录可能产生延迟影响。

---

## Part 2：语音识别模型与能力

### 2.1 Ursa 2 模型

Speechmatics 当前主力模型为 **Ursa 2**，采用自监督学习（SSL）架构。

| 项目 | 详情 |
|------|------|
| 架构 | 自监督学习（SSL）+ 语言模型 |
| 预训练数据 | 100 万+ 小时无标注音频，覆盖 50+ 语言 |
| SSL 模型规模 | ~20 亿参数（2B） |
| 语言模型 | 相比上代扩大 30 倍 |
| 推理硬件 | GPU 推理 |

### 2.2 精度基准

- 整体 WER 比上代 Ursa 降低 **18%**
- 西班牙语：WER 3.3（96.7% 准确率），市场领先
- 波兰语：WER 4.4（95.6% 准确率），市场领先
- **62% 的语言排名市场第一，92% 的语言排名前三**
- 实时转录延迟 < 1 秒

### 2.3 特色能力

- **自动标点和大写**：语言特定的标点、逗号、问号、感叹号，可调节标点密度（默认 0.5）
- **自定义词典（Custom Dictionary）**：支持添加专有名词、行业术语、缩写等
- **词语替换（Word Replacement）**：搜索替换模式，可自动修正特定词汇
- **去除填充词（Disfluency Removal）**：过滤 "嗯"、"啊" 等语气词
- **无幻觉模型**：企业版和医疗版声称 "hallucination-free"

---

## Part 3：多语种混杂（Code-Switching）支持

这是 Speechmatics 最突出的差异化优势。

### 3.1 支持的 Code-Switching 语言对

| 语言对 | 代码 | 说明 |
|-------|------|------|
| **中文普通话 + 英语** | `cmn_en` | 支持同一句话中中英混杂 |
| 阿拉伯语 + 英语 | `ar_en` | 阿英混杂 |
| 马来语 + 英语 | `en_ms` | 马英混杂 |
| 泰米尔语 + 英语 | `en_ta` | 泰英混杂 |
| 塔加洛语（菲律宾语）+ 英语 | `tl` | 菲英混杂 |
| 西班牙语 + 英语 | `es` + `domain='bilingual-en'` | 西英混杂 |
| **中文 + 马来语 + 泰米尔语 + 英语** | `cmn_en_ms_ta` | 四语混杂（新加坡场景） |

### 3.2 中英混杂能力评估

**关键发现：Speechmatics 明确支持 `cmn_en`（普通话-英语）code-switching。**

- 可在同一音频流/文件中处理中英混杂语音
- 无需预先指定哪段是中文、哪段是英文，模型自动检测切换
- Code-switching 错误率比最接近竞品低 **35%**（官方宣称）
- 四语包 `cmn_en_ms_ta` 甚至支持中英马泰四种语言同时出现

### 3.3 对 WhisperUtil 的意义

当前 WhisperUtil 使用 OpenAI Whisper API（gpt-4o-transcribe），Whisper 对中英混杂的处理能力有限——倾向于将整段识别为中文或整段识别为英文，在句内 code-switching 时容易丢失另一种语言的内容。

Speechmatics 的 `cmn_en` 模式可能在以下场景显著优于 Whisper：
- 技术讨论中夹杂英文术语（如 "这个 API 的 response time 太长了"）
- 中英双语会议
- 口语中频繁切换中英文的用户

---

## Part 4：流式 vs 批量转录

### 4.1 实时转录（Real-Time / Streaming）

| 项目 | 详情 |
|------|------|
| 协议 | WebSocket (`wss://`) |
| 端点示例 | `wss://eu.rt.speechmatics.com/v2` |
| 延迟 | < 1 秒（Partial transcripts < 500ms） |
| 并发限制 | Free: 2 会话，Pro: 50 会话 |
| 消息类型 | `StartRecognition` → 音频流 → `AddTranscript` / `AddPartialTranscript` |

**输出类型：**
- **Partial Transcripts**：低延迟（< 500ms），可能被后续修正
- **Final Transcripts**：确定性结果，不再更新

**关键配置：**
- `max_delay`：延迟/精度权衡参数
- `enable_partials`：是否启用部分转录
- `transcript_filtering_config`：去除填充词等

### 4.2 批量转录（Batch）

- 通过 REST API 上传音频文件
- 支持异步处理，适合长音频
- 与实时 API 配置基本一致（`transcription_config` 格式相同）
- 批量模式支持更丰富的说话人分离选项

### 4.3 与 WhisperUtil 架构的对应

| WhisperUtil 现有模式 | Speechmatics 对应 |
|---------------------|-------------------|
| Cloud（gpt-4o-transcribe，HTTP） | Batch API（REST） |
| Realtime（WebSocket 流式） | Real-time API（WebSocket） |
| Local（WhisperKit 本地） | On-Device 部署（需企业版） |

---

## Part 5：收费情况

### 5.1 定价层级

| 层级 | 价格 | 免费额度 | 并发限制 | 其他 |
|------|------|---------|---------|------|
| **Free** | $0 | 480 分钟/月（8 小时） | 2 实时会话 | 无需信用卡 |
| **Pro** | 起价 $0.24/hr | 480 分钟/月 | 50 实时会话 | 用量上限 6,000 小时/月 |
| **Enterprise** | 定制报价 | 协商 | 无限制 | 私有化部署、专属客户经理 |

### 5.2 优惠政策

- **超量折扣**：月用量超 500 小时，自动享 20% 折扣
- **年度折扣**：年用量超 24,000 小时，额外折扣
- **创业公司计划**：$50,000+ 的 API 额度，含全功能访问和专属对接

### 5.3 与 OpenAI Whisper API 价格对比

| 服务 | 单价 | 免费额度 |
|------|------|---------|
| OpenAI gpt-4o-transcribe | $0.006/min ($0.36/hr) | 无 |
| Speechmatics Pro | ~$0.004/min ($0.24/hr) | 480 分钟/月 |
| Deepgram Nova-2 | ~$0.0043/min ($0.26/hr) | 有限 |

> Speechmatics 按时长计费，单价实际上**低于** OpenAI Whisper API，且有免费额度。但需注意，code-switching 语言包是否加价需要确认。

---

## Part 6：API 特性详览

### 6.1 说话人分离（Speaker Diarization）

- **声纹分离**：通过声音特征区分不同说话人
- **通道分离**：多声道音频各自独立转录
- **通道 + 声纹**：多声道中再区分多个说话人
- 支持与情感分析联动，获取每个说话人的情感倾向

### 6.2 情感分析（Sentiment Analysis）

- 对转录文本段落标注 positive / negative / neutral
- 附带置信度分数
- 可与 diarization 联动，分析每个说话人的整体情感

### 6.3 翻译（Translation）

- 单次 API 调用同时获得转录 + 翻译
- 支持 30+ 语言到英语的翻译
- 支持 69 个语言对的实时翻译

### 6.4 其他特性

| 特性 | 说明 |
|------|------|
| 自定义词典 | 添加专有名词、行业术语 |
| 词语替换 | 自动搜索替换模式 |
| 实体格式化 | 数字、日期等自动格式化 |
| 去填充词 | 过滤 "um", "uh" 等 |
| 自动标点 | 标点密度可调 |
| 医疗模型 | 医学术语优化（英语、西班牙语） |

---

## Part 7：集成方式

### 7.1 官方 SDK

| SDK | 语言 | 功能 |
|-----|------|------|
| speechmatics-python | Python | Realtime + Batch API |
| speechmatics-js-sdk | JavaScript/TypeScript | Realtime + Batch API |

**没有原生 Swift/Objective-C SDK。**

### 7.2 集成到 WhisperUtil 的方案

由于没有 Swift SDK，集成需要：

1. **WebSocket 直连**：使用 Swift 原生 `URLSessionWebSocketTask` 对接实时转录 API
   - 协议：`wss://eu.rt.speechmatics.com/v2`（或 `us` 区域）
   - 发送 `StartRecognition` JSON 消息
   - 流式发送音频二进制数据
   - 接收 `AddTranscript` / `AddPartialTranscript` 事件
   - 复杂度中等，与现有 `ServiceRealtimeOpenAI` 的 WebSocket 实现类似

2. **REST API 批量转录**：使用 `URLSession` 发送 HTTP 请求
   - 上传音频文件 + JSON 配置
   - 轮询或等待结果
   - 复杂度低，与现有 `ServiceCloudOpenAI` 类似

3. **第三方集成平台**：
   - LiveKit、Pipecat、Vapi 等平台原生集成 Speechmatics
   - 但对 WhisperUtil 这种轻量级工具来说过于重量级

### 7.3 认证方式

- API Key 认证
- 可存入 macOS Keychain（与现有 `KeychainHelper` 复用）

---

## Part 8：与竞品对比

| 维度 | Speechmatics | OpenAI Whisper | Deepgram | Google Cloud STT | AssemblyAI |
|------|-------------|---------------|----------|-----------------|------------|
| 中英 code-switching | 原生支持 `cmn_en` | 不支持原生切换 | 有限支持 | 支持（Chirp 3） | 不支持 |
| 语言数 | 55+ | 100+ | 36+ | 100+ | 英语为主 |
| 实时流式 | WebSocket | Realtime API | WebSocket | gRPC/WebSocket | WebSocket |
| 延迟 | < 1s | 较高 | < 300ms | 中等 | 中等 |
| 单价 | ~$0.24/hr | ~$0.36/hr | ~$0.26/hr | ~$0.24/hr | ~$0.37/hr |
| 免费额度 | 480 min/月 | 无 | 有限 | $300 新用户 | 有限 |
| 私有化部署 | 支持 | 可自部署开源模型 | 支持 | 不支持 | 不支持 |
| Swift SDK | 无 | 无（HTTP 即可） | 无 | 有（gRPC） | 无 |
| 精度（综合） | 优秀（62% 语言第一） | 优秀 | 良好 | 良好 | 优秀（英语） |
| 情感分析 | 内置 | 无 | 无 | 无 | 内置 |
| 说话人分离 | 支持 | 不支持 | 支持 | 支持 | 支持 |

### 8.1 Speechmatics 核心优势

1. **Code-switching 业界领先**：尤其是 `cmn_en` 中英混杂，这是最大差异化
2. **价格竞争力**：比 OpenAI 便宜，且有免费额度
3. **企业级合规**：GDPR、HIPAA、SOC 2
4. **部署灵活性**：云、本地、端侧均可

### 8.2 Speechmatics 核心劣势

1. **无 Swift SDK**：需手动对接 WebSocket/REST
2. **中国大陆无节点**：延迟问题
3. **生态较小**：社区和文档不如 OpenAI 丰富
4. **TTS 仅英语**：如果未来需要语音合成，语言覆盖有限

---

## Part 9：已知问题与局限性

### 9.1 技术局限

- **中国大陆无服务器**：实时转录可能因网络延迟受影响，这对 WhisperUtil 的中国用户是关键问题
- **延迟不是最低**：实时延迟 < 1 秒，但 Deepgram 可达 < 300ms
- **自定义词典 bug**：曾有词典首项为连字符时导致会话失败的问题（已修复）
- **模型参数未公开**：Ursa 2 的具体架构细节和完整参数量未公开

### 9.2 用户反馈的问题

- 部分用户反映处理速度偶尔出现延迟波动
- 某些口音（多说话人场景）的识别准确度有待提升
- 移动端开发支持较弱
- 文档部分区域不够详尽
- 定价对小型团队/个人开发者偏高

### 9.3 对 WhisperUtil 集成的风险

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| 无 Swift SDK | 开发工作量增加 | 复用现有 WebSocket 架构 |
| 中国大陆延迟 | 实时转录体验差 | 提供区域选择或回退到 OpenAI |
| API 变更 | 维护成本 | 抽象 Service 层已有，新增 Backend 即可 |
| 免费额度用尽 | 用户需付费 | 明确提示用量和费用 |

---

## Part 10：集成建议与路线图

### 10.1 是否值得集成？

**结论：值得作为可选后端，但不是短期优先事项。**

- 如果用户群体中有大量中英混杂使用需求，Speechmatics 的 `cmn_en` 是当前最佳解决方案
- 架构上，WhisperUtil 已有 `ServiceCloudOpenAI` 和 `ServiceRealtimeOpenAI` 的抽象，新增一个 `ServiceSpeechmatics` 的工作量可控
- 但考虑到维护成本和用户群规模，建议先观察需求再决定

### 10.2 如果集成，建议方案

1. **新增 `ServiceSpeechmaticsRealtime`**：参照 `ServiceRealtimeOpenAI`，实现 WebSocket 流式转录
2. **新增 `ServiceSpeechmacticsBatch`**：参照 `ServiceCloudOpenAI`，实现 REST 批量转录
3. **API Key 管理**：复用 `KeychainHelper`，在 Settings 中新增 Speechmatics API Key 输入
4. **语言配置**：在设置中暴露 language pack 选项（如 `cmn_en`、`en` 等）
5. **Config 新增模式**：在现有 Local / Cloud / Realtime 三模式之外，新增 Speechmatics 选项

### 10.3 优先级评估

| 优先级 | 理由 |
|-------|------|
| **中低** | 当前 OpenAI 方案覆盖绝大多数场景；code-switching 需求需验证用户量；无 Swift SDK 增加开发成本 |

---

## Part 11: 补充：跨语言对 Code-Switching 评测数据

### 各服务多语言对 CS 支持矩阵

| 服务 | 支持的 CS 语言对 | 日+英 | 中+日 | 西+英 | 韩+英 | 印地+英 |
|------|-----------------|:-----:|:-----:|:-----:|:-----:|:------:|
| Deepgram Nova-3 | en/es/fr/de/hi/ru/pt/ja/it/nl 共10语互切 | ✅ | ❌ | ✅ | ❌ | ✅ |
| **Speechmatics** | **专门双语包：cmn+en, ar+en, ms+en, ta+en, fil+en** | **❌** | **❌** | **⚠️ 需特殊配置** | **❌** | **❌** |
| Soniox | 宣称 60+ 语言统一模型自动检测 | ❓ 无专项数据 | ❓ | ❓ | ❓ | ❓ |
| Whisper/gpt-4o-transcribe | 理论99语言，无专门CS优化 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| ElevenLabs | 仅优化印度语-英语 | ❌ | ❌ | ❌ | ❌ | ⚠️ |
| Mistral Voxtral | 声称13语言切换，无专项数据 | ❓ | ❓ | ❓ | ❓ | ❓ |
| Apple SFSpeechRecognizer | 单语言，不支持CS | ❌ | ❌ | ❌ | ❌ | ❌ |
| Groq (Whisper) | 同 Whisper 模型 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |

**结论：没有一个服务能覆盖所有语言对的 code-switching。** Speechmatics 的核心优势在于提供 **专门的双语言包**（如 `cmn_en`），通过针对性训练实现高质量的特定语言对 CS。虽然覆盖的语言对数量有限，但在已支持的语言对上（尤其是中英 `cmn_en`），其 CS 错误率比最接近竞品低 35%，质量业界领先。

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

> 对 Speechmatics 而言，其 `cmn_en` 双语包直接对标 SEAME 和 ASCEND 数据集的场景（新加坡/香港的中英混杂对话）。Speechmatics 官方宣称 CS 错误率比竞品低 35%，如能在 SEAME 上公开具体 MER 数据与 Whisper 的 14-20% 做对比，将极具说服力。此外，Speechmatics 的四语包 `cmn_en_ms_ta` 对标的正是新加坡多语种场景，与 SEAME 数据集高度吻合。

### 学术界核心趋势

- 参数高效微调(LoRA/Adapter) + 语言识别引导解码 + 合成数据增强是三大主线
- 微调后 MER 可相对降 4-7%

---

## 参考资料

- [Speechmatics 官网](https://www.speechmatics.com/)
- [Speechmatics 定价页面](https://www.speechmatics.com/pricing)
- [Speechmatics 语言支持文档](https://docs.speechmatics.com/speech-to-text/languages)
- [Ursa 2 发布文章](https://www.speechmatics.com/company/articles-and-news/ursa-2-elevating-speech-recognition-across-52-languages)
- [实时转录 API 指南](https://docs.speechmatics.com/introduction/rt-guide)
- [WebSocket API 参考](https://docs.speechmatics.com/api-ref/realtime-transcription-websocket)
- [Speechmatics Python SDK (GitHub)](https://github.com/speechmatics/speechmatics-python)
- [Speechmatics JS SDK (GitHub)](https://github.com/speechmatics/speechmatics-js-sdk)
- [Speechmatics AI 信息页](https://www.speechmatics.com/ai-info)
- [Speechmatics 2025 回顾](https://www.speechmatics.com/company/articles-and-news/speechmatics-in-2025-the-numbers-that-shaped-voice-ais-breakthrough-year)
- [情感分析文档](https://docs.speechmatics.com/speech-to-text/batch/speech-intelligence/sentiment-analysis)
- [说话人分离文档](https://docs.speechmatics.com/speech-to-text/features/diarization)
- [集成与 SDK 文档](https://docs.speechmatics.com/integrations-and-sdks/sdks)
