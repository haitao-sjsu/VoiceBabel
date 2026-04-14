# ElevenLabs 语音转文字（STT）调研

日期：2026-04-14
背景：WhisperUtil macOS 语音转文字工具开发中，评估是否值得集成 ElevenLabs STT

---

## Part 1：公司概述与 STT 产品定位

ElevenLabs 成立于 2022 年，以 Text-to-Speech（TTS）技术闻名，其语音合成质量在业界处于领先地位。2025 年起，ElevenLabs 推出了 **Scribe** 系列语音转文字模型，正式进入 STT 领域。

**STT 产品定位**：
- 与其 TTS、Conversational AI Agents 平台形成完整语音 AI 生态
- 主打"最精准的 STT 模型"，在 FLEURS 基准测试上声称行业最低 WER
- 面向批量转录（字幕、内容分析）和实时转录（语音 Agent、会议助手）两大场景
- 企业级合规：SOC 2、ISO 27001、PCI DSS L1、HIPAA、GDPR

---

## Part 2：STT 模型和能力

### 2.1 模型列表

| 模型 | model_id | 定位 | 语言数 |
|------|----------|------|--------|
| Scribe v1 | `scribe_v1` | 已被 v2 超越，不推荐 | 90+ |
| **Scribe v2** | `scribe_v2` | 批量转录，功能最全 | 90+ |
| **Scribe v2 Realtime** | `scribe_v2_realtime` | 实时流式，超低延迟 | 90+ |

### 2.2 Scribe v2（批量模型）核心能力

- 词级时间戳（word-level timestamps）
- 说话人分离（speaker diarization），最多 **32 个说话人**
- 实体检测（entity detection），支持 **56 种实体类型**（PII、健康数据、支付信息等）
- 实体脱敏（entity redaction）：完全脱敏 `[REDACTED]`、分类脱敏 `[CREDIT_CARD]`、编号脱敏 `[CREDIT_CARD_1]`
- 关键词提示（keyterm prompting），最多 **1,000 个术语**
- 动态音频标签（audio tagging）：检测笑声、脚步声等非语音事件
- 智能语言检测（smart language detection）
- No Verbatim 模式：自动去除填充词（um、uh）和重复
- 文件大小上限 **3 GB**，时长上限 **10 小时**（多声道模式 1 小时）
- 多声道支持：最多 **5 个声道**独立处理

### 2.3 Scribe v2 Realtime（实时模型）核心能力

- 延迟 **~150ms**
- 准确率：30 种常用语言平均 **93.5%**
- 负延迟预测（next word and punctuation prediction）
- 语音活动检测（VAD）
- 手动 commit 控制
- 支持 PCM（8k~48kHz）和 μ-law（8kHz）音频格式

**注意**：Realtime 模型 **不支持** 说话人分离、实体检测、关键词提示等高级功能，这些仅在批量模型中可用。

---

## Part 3：多语种混杂（Code-Switching）支持

### 3.1 当前状态

- Scribe v2 支持 **自动多语言检测**：单个音频文件中包含多种语言时，模型能自动检测并正确转录，无需手动指定语言
- 2026 年升级新增 **Indic-English Code-Switching**：印度语言（Hindi、Telugu、Kannada 等）与英语混杂时，英语部分保持拉丁字母输出，不会被音译为印度文字
- 实测中，英西混杂（Spanglish）能较好切换，保持语言准确性

### 3.2 中英混杂评估

- 普通话（Mandarin，cmn）属于 **High Accuracy** 级别（WER 5%~10%）
- 官方 **未明确宣称** 支持中英 code-switching
- Indic-English 的 code-switching 是专门优化的功能，中英混杂是否有同等效果 **未知**
- 中文（普通话）的自动语言检测是支持的，但 **中英夹杂的句子级切换** 质量需要实际测试验证

### 3.3 对 WhisperUtil 的影响

- 如果用户场景主要是纯中文或纯英文，Scribe v2 的准确率有竞争力
- 如果需要中英频繁混杂（如技术讨论），**目前没有证据表明 ElevenLabs 比 OpenAI gpt-4o-transcribe 或 Whisper 更好**
- 建议：如果考虑集成，需先用中英混杂音频样本进行 API 测试

---

## Part 4：流式 vs 批量转录能力

### 4.1 批量转录（Scribe v2）

- **协议**：REST API（HTTP POST）
- **端点**：`POST /v1/speech-to-text`
- 支持 Webhook 异步回调
- 超过 8 分钟的文件会自动内部并发加速
- 支持格式：AAC、MP3、WAV、FLAC、WebM、OGG、OPUS、AIFF、M4A（音频）；MP4、AVI、MKV、MOV（视频）

### 4.2 实时转录（Scribe v2 Realtime）

- **协议**：WebSocket（WSS）
- **连接地址**：
  - 默认：`wss://api.elevenlabs.io/`
  - 美国：`wss://api.us.elevenlabs.io/`
  - 欧盟：`wss://api.eu.residency.elevenlabs.io/`
  - 印度：`wss://api.in.residency.elevenlabs.io/`
- **认证**：`xi-api-key` Header 或 `token` Query Parameter（客户端单次令牌）
- **消息类型**：
  - 客户端发送：`input_audio_chunk`（base64 编码音频）
  - 服务器返回：`session_started`、`partial_transcript`（中间结果）、`committed_transcript`（最终结果）、`committed_transcript_with_timestamps`
- **关键参数**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `audio_format` | pcm_16000 | PCM 或 μ-law 编码 |
| `commit_strategy` | manual | manual 或 vad |
| `vad_silence_threshold_secs` | 1.5 | 静音检测阈值 |
| `vad_threshold` | 0.4 | 语音活动阈值 |
| `include_timestamps` | false | 词级时间戳 |
| `include_language_detection` | false | 语言检测 |
| `enable_logging` | true | false 时启用零保留模式 |

### 4.3 与 WhisperUtil 现有架构对比

| 能力 | WhisperUtil 现有 | ElevenLabs |
|------|-----------------|------------|
| 批量 HTTP | Cloud（gpt-4o-transcribe）| Scribe v2 REST |
| 实时 WebSocket | Realtime（OpenAI GA WebSocket）| Scribe v2 Realtime WSS |
| 本地离线 | WhisperKit | 不支持 |

ElevenLabs 的架构与 WhisperUtil 现有的 Cloud + Realtime 双模式 **高度类似**，集成难度不大。

---

## Part 5：收费情况

### 5.1 Scribe v2 批量转录

| 套餐 | 月费 | 含 STT 时长 | 超出单价 |
|------|------|-------------|----------|
| Free | $0 | 4.5 小时 | - |
| Starter | $6 | 27 小时 | $0.22/h |
| Creator | $22 | 100 小时 | $0.22/h |
| Pro | $99 | 450 小时 | $0.22/h |
| Scale | $299 | 1,359 小时 | $0.22/h |
| Business | $990 | 4,500 小时 | $0.22/h |

**附加费用**：
- 实体检测：+$0.07/h
- 关键词提示：+$0.05/h

### 5.2 Scribe v2 Realtime

| 套餐 | 含 STT Realtime 时长 | 超出单价 |
|------|---------------------|----------|
| Free | 2.5 小时 | - |
| Starter | 15 小时 | $0.39/h |
| Creator | 56 小时 | $0.39/h |
| Pro | 254 小时 | $0.39/h |
| Scale | 767 小时 | $0.39/h |
| Business | 2,538 小时 | $0.39/h |

### 5.3 免费额度

- 免费计划每月 **10,000 Credits**
- 批量 STT 约含 **4.5 小时**
- 实时 STT 约含 **2.5 小时**
- 无需信用卡即可开始

### 5.4 与 OpenAI 价格对比

| 服务 | 批量单价 | 实时单价 |
|------|----------|----------|
| ElevenLabs Scribe v2 | $0.22/h | $0.39/h |
| OpenAI gpt-4o-transcribe | $0.006/min ≈ $0.36/h | - |
| OpenAI Whisper API | $0.006/min ≈ $0.36/h | - |
| OpenAI Realtime API (audio input) | $0.06/min ≈ $3.60/h | $3.60/h |

**结论**：ElevenLabs 批量转录 **$0.22/h 显著便宜于 OpenAI 的 $0.36/h**。实时转录 **$0.39/h 远低于 OpenAI Realtime API 的 $3.60/h**（但 OpenAI Realtime 包含 LLM 推理能力，不是纯 STT）。

---

## Part 6：API 特性详解

### 6.1 说话人分离（Diarization）

- 仅批量模式支持，最多 32 个说话人
- 注意：**8 分钟以内的音频效果最佳**，较长音频的说话人识别质量可能下降

### 6.2 时间戳

- 批量模式：词级时间戳
- 实时模式：通过 `include_timestamps=true` 获取词级时间戳和说话人 ID

### 6.3 标点与格式化

- 自动添加标点
- No Verbatim 模式去除填充词和重复

### 6.4 实体检测与脱敏

- 56 种实体类型（PII、健康、支付等）
- 三种脱敏模式
- 注意：自动化脱敏**不保证识别或移除所有敏感信息**

### 6.5 关键词提示

- 最多 1,000 个术语
- 适合专业领域术语、品牌名称
- 超过 100 个术语时，最低计费单位为 20 秒

### 6.6 音频标签

- 检测非语音事件（笑声、脚步声等）
- 仅批量模式

---

## Part 7：集成方式

### 7.1 官方 SDK

| 语言/平台 | 包名 | 类型 |
|-----------|------|------|
| Python | `elevenlabs` (PyPI) | REST + Agents |
| JavaScript/TypeScript | `@elevenlabs/elevenlabs-js` (npm) | REST |
| JavaScript (Agents) | `@elevenlabs/client` (npm) | Agents |
| React | `@elevenlabs/react` (npm) | Agents |
| React Native | `@elevenlabs/react-native` (npm) | Agents |
| **Swift** | `ElevenLabsSwift` (GitHub) | **Agents 平台** |
| Kotlin | Maven Central | Agents |
| Flutter | `elevenlabs_agents` (pub.dev) | Agents |

### 7.2 Swift / macOS 集成评估

- 官方 Swift SDK（`ElevenLabsSwift`）**主要面向 Conversational AI Agents 平台**，不是通用 REST API 封装
- 要求 iOS 14.0+ / macOS 11.0+，Swift 5.9+
- STT REST API 可直接用 `URLSession` 调用，无需 SDK
- STT WebSocket（Realtime）可直接用 `URLSessionWebSocketTask` 或 NIO 实现
- **社区库**：`steipete/ElevenLabsKit`（第三方，主要针对 TTS）

### 7.3 对 WhisperUtil 的集成建议

- **批量模式**：直接 HTTP POST，与现有 `ServiceCloudOpenAI` 模式类似
- **实时模式**：WebSocket 连接，与现有 `ServiceRealtimeOpenAI` 模式类似
- 认证方式：API Key（`xi-api-key` Header），可复用现有 Keychain 存储方案
- 无需引入额外 SDK 依赖，原生 Swift 网络 API 即可完成

---

## Part 8：与其他 STT 服务的对比

### 8.1 准确率对比

| 模型 | WER（英语）| 多语言支持 | 延迟 |
|------|-----------|-----------|------|
| ElevenLabs Scribe v2 | ~3.5% | 90+ 语言 | 批量 |
| ElevenLabs Scribe v2 RT | 6.5%（30 语言均值）| 90+ 语言 | ~150ms |
| OpenAI gpt-4o-transcribe | ~4-5% | 50+ 语言 | 批量 |
| OpenAI Whisper v3 | ~7.6% | 99 语言 | 批量 |
| Deepgram Nova-3 | ~6.8% | 36 语言 | <300ms |
| Google Chirp 2 | ~11.6% | 100+ 语言 | 批量/流式 |

### 8.2 特色优势

- **ElevenLabs**：准确率领先、实体检测/脱敏、关键词提示、音频标签
- **OpenAI**：生态成熟、与 GPT 集成方便、Whisper 开源可本地运行
- **Deepgram**：低延迟流式、定制模型训练、噪音环境表现好
- **Google**：语言数量最多、云生态整合

### 8.3 WhisperUtil 视角的对比

| 维度 | OpenAI（现有）| ElevenLabs |
|------|--------------|------------|
| 批量准确率 | 好 | 更好 |
| 实时准确率 | 好 | 相当 |
| 中英混杂 | gpt-4o-transcribe 表现不错 | 未明确支持，需测试 |
| 价格（批量）| $0.36/h | $0.22/h（便宜 39%）|
| 价格（实时）| $3.60/h（含 LLM）| $0.39/h（纯 STT）|
| 翻译 | Whisper API 内置 | 不支持 |
| 本地离线 | WhisperKit | 不支持 |
| SDK 成熟度 | 官方 Swift 未覆盖 STT | 官方 Swift 仅 Agents |
| 附加功能 | 无 | 实体检测、说话人分离、音频标签 |

---

## Part 9：已知问题和局限性

### 9.1 功能局限

1. **无翻译功能**：Scribe 仅做转录，不支持语音翻译（WhisperUtil 的翻译功能无法用 ElevenLabs 替代）
2. **无本地/离线模式**：纯云服务，无法离线使用
3. **Realtime 功能受限**：实时模式不支持说话人分离、实体检测、关键词提示
4. **Code-switching 有限**：仅 Indic-English 有专门优化，中英混杂未验证
5. **说话人分离时长限制**：超过 8 分钟的音频，说话人识别效果下降

### 9.2 技术问题

1. **WebSocket 重连**：WebSocket 中途断开后，流不会自动重连，转录可能出现乱码
2. **实体脱敏不完整**：官方声明自动脱敏可能遗漏敏感信息
3. **第三方集成问题**：在 LiveKit 等框架中集成 Scribe v2 Realtime 时，有用户报告产生零时长转录（stt_audio_duration=0.0）
4. **关键词提示计费**：超过 100 个术语时最低计费 20 秒

### 9.3 对 WhisperUtil 的风险评估

- **中英混杂**是 WhisperUtil 用户的核心场景之一，ElevenLabs 在此方面**缺乏明确支持**
- WhisperUtil 已有完整的 Cloud + Realtime + Local 三模式架构，增加 ElevenLabs 作为**第四个后端**会增加维护复杂度
- ElevenLabs 的差异化优势（实体检测、说话人分离等）对 WhisperUtil 的"输入到光标位置"场景意义不大

---

## Part 10: 补充：跨语言对 Code-Switching 评测数据

### 各服务多语言对 CS 支持矩阵

| 服务 | 支持的 CS 语言对 | 日+英 | 中+日 | 西+英 | 韩+英 | 印地+英 |
|------|-----------------|:-----:|:-----:|:-----:|:-----:|:------:|
| Deepgram Nova-3 | en/es/fr/de/hi/ru/pt/ja/it/nl 共10语互切 | ✅ | ❌ | ✅ | ❌ | ✅ |
| Speechmatics | 专门双语包：cmn+en, ar+en, ms+en, ta+en, fil+en | ❌ | ❌ | ⚠️ 需特殊配置 | ❌ | ❌ |
| Soniox | 宣称 60+ 语言统一模型自动检测 | ❓ 无专项数据 | ❓ | ❓ | ❓ | ❓ |
| Whisper/gpt-4o-transcribe | 理论99语言，无专门CS优化 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| **ElevenLabs** | **仅优化印度语-英语** | **❌** | **❌** | **❌** | **❌** | **⚠️** |
| Mistral Voxtral | 声称13语言切换，无专项数据 | ❓ | ❓ | ❓ | ❓ | ❓ |
| Apple SFSpeechRecognizer | 单语言，不支持CS | ❌ | ❌ | ❌ | ❌ | ❌ |
| Groq (Whisper) | 同 Whisper 模型 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |

**结论：没有一个服务能覆盖所有语言对的 code-switching。** ElevenLabs 目前仅对 Indic-English CS 有专门优化，中英、日英等其他语言对的 CS 支持仍为空白。

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

> 对 ElevenLabs 而言，其 Indic-English CS 优化展示了针对特定语言对做专项适配的价值。如果 ElevenLabs 能将类似优化扩展到中英、日英等语言对，将显著提升其 STT 产品在东亚市场的竞争力。

### 学术界核心趋势

- 参数高效微调(LoRA/Adapter) + 语言识别引导解码 + 合成数据增强是三大主线
- 微调后 MER 可相对降 4-7%

---

## 总结与建议

### 值得关注的点
- 批量转录准确率领先，价格比 OpenAI 便宜约 39%
- 实时转录延迟低（150ms），价格远低于 OpenAI Realtime API
- 企业级功能丰富（实体检测、说话人分离、脱敏）

### 暂不建议集成的理由
1. **中英混杂支持不明确** —— WhisperUtil 的核心用户场景
2. **无翻译功能** —— 无法替代现有翻译能力
3. **现有架构已足够** —— 三模式覆盖离线/在线/流式
4. **增量收益有限** —— ElevenLabs 的差异化功能（实体检测、说话人分离）不符合 WhisperUtil 的"快速输入"定位

### 建议的后续行动
- 如果未来有批量转录/会议记录场景需求，可重新评估
- 如果 ElevenLabs 后续推出中英 code-switching 支持，值得再次测试
- 保持关注 ElevenLabs STT 产品演进

---

*信息来源：ElevenLabs 官方文档、博客、API Reference（2026-04-14 访问）*
