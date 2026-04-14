# Mistral AI 语音识别调研

**日期**: 2026-04-14
**背景**: macOS 语音转文字工具 WhisperUtil 开发中，竞品 VoiceInk 已集成 Mistral 实时语音转写，评估是否值得集成。

---

## Part 1: Mistral 语音产品概述

Mistral AI 是一家法国 LLM 公司，2025 年 7 月推出 **Voxtral** 语音模型系列，正式进入语音领域。Mistral 的语音方案**不是**通过通用多模态大模型附带语音能力，而是推出了**专用的语音模型产品线**：

| 产品 | 类型 | 发布时间 |
|------|------|----------|
| Voxtral Small (24B) | 语音理解 + 聊天 (audio-in LLM) | 2025-07 |
| Voxtral Mini (3B) | 语音理解 + 聊天 (audio-in LLM) | 2025-07 |
| Voxtral Mini Transcribe V2 | 专用 STT (批量转写) | 2026-02 |
| Voxtral Mini Realtime | 专用 STT (实时流式) | 2026-02 |
| Voxtral TTS | 文本转语音 (TTS) | 2026-03 |

关键定位：
- **有独立的 STT API**，端点为 `/v1/audio/transcriptions`，与 OpenAI Whisper API 接口风格类似
- Voxtral Small/Mini 是多模态 LLM，可通过 chat completions 接口接收音频输入做问答/摘要
- Voxtral Mini Transcribe V2 是专门为转写优化的模型，精度更高、成本更低
- Voxtral Realtime 是专为实时场景设计的流式模型

## Part 2: 语音识别模型和能力

### 2.1 Voxtral Mini Transcribe V2 (批量转写)

- **模型 ID**: `voxtral-mini-2602` / `voxtral-mini-latest`
- **用途**: 离线/批量转写，处理录音文件
- **最大时长**: 单次请求支持最长 3 小时音频
- **支持格式**: .mp3, .wav, .m4a, .flac, .ogg，文件最大 1GB
- **WER 性能**: FLEURS 基准约 4%，英语约 3.2%
- **核心特性**:
  - **说话人分离 (diarization)**: 自动识别和标注不同说话人
  - **上下文偏置 (context_bias)**: 可提供最多 100 个领域专有词汇提升识别准确率
  - **词级时间戳 (word-level timestamps)**: 精确到每个词的时间
  - **段级时间戳 (segment-level timestamps)**
  - **噪声鲁棒性**: 在嘈杂环境中维持精度
  - **自动语言检测**: 无需手动指定语言

### 2.2 Voxtral Mini Realtime (实时流式)

- **模型 ID**: `voxtral-mini-transcribe-realtime-2602`
- **参数量**: 4B (语言模型 ~3.4B + 音频编码器 ~970M)
- **架构**: 因果音频编码器 + 滑动窗口注意力，原生流式设计（非离线模型的分块适配）
- **延迟**: 可配置 80ms ~ 2400ms，推荐 480ms（精度与延迟的甜点）
- **WER 性能**:
  - 480ms 延迟：FLEURS 平均 8.72%，英语 4.90%
  - 2400ms 延迟：接近 Transcribe V2 离线精度
  - LibriSpeech Clean: 2.08%，Other: 5.52%
- **开源**: Apache 2.0 许可，权重在 Hugging Face 公开
- **限制**: 实时模式**不支持** diarization

### 2.3 Voxtral Small (24B, 语音理解)

- **模型 ID**: `voxtral-small-latest`
- **用途**: 音频输入的聊天/问答/摘要，不是纯 STT
- **WER**: 英语 2.1%（所有 Voxtral 中最低），多语言 3.8%
- **定位**: 更适合语音理解任务，不适合纯转写场景

## Part 3: 多语种混杂 (Code-Switching) 支持

### 支持的 13 种语言

英语、中文、印地语、西班牙语、阿拉伯语、法语、葡萄牙语、俄语、德语、日语、韩语、意大利语、荷兰语。

### Code-Switching 能力

- 官方声称**支持在同一音频中的语言切换 (code-switching)**，无需手动配置
- 模型会自动检测源音频语言并转写
- 但 **code-switching 的具体精度没有公开基准数据**
- 上下文偏置 (context_bias) 功能目前**主要针对英语优化**，其他语言为实验性支持
- 中英混杂场景的实际表现**没有找到可靠的第三方测评数据**

### 与 WhisperUtil 的相关性

对于中英混杂场景（WhisperUtil 的核心使用场景之一），Mistral 虽然声称支持，但：
1. 没有专门的 code-switching 基准测试结果
2. context_bias 对中文支持仍是实验性的
3. 13 种语言中包含中文和英文，但混杂质量未知

**结论**: 中英混杂能力待实测验证，不能仅凭官方声称作为决策依据。

## Part 4: 实时/流式转录能力

### 协议

Voxtral Realtime 使用 **WebSocket** 协议进行实时流式转写。

### 音频格式要求

- 编码: PCM 16-bit little-endian (pcm_s16le)
- 采样率: 16,000 Hz
- 输入: 异步提供的字节流

### 关键配置

- `target_streaming_delay_ms`: 控制等待时间再开始转写，越长精度越高
- 推荐值: 480ms（精度接近离线，延迟可接受）

### 事件类型

| 事件 | 说明 |
|------|------|
| `RealtimeTranscriptionSessionCreated` | 会话初始化 |
| `TranscriptionStreamTextDelta` | 增量转写文本 |
| `TranscriptionStreamDone` | 转写完成 |
| `RealtimeTranscriptionError` | 错误通知 |

### Python 示例

```python
# pip install mistralai[realtime]
# 使用 client.audio.realtime.transcribe_stream() 异步迭代事件流
```

### VoiceInk 的集成经验

VoiceInk (macOS 竞品) 已集成 Voxtral Realtime，但用户报告存在**间歇性故障**:
- GitHub Issue #533: 模型 ID `voxtral-mini-transcribe-realtime-2602` 间歇返回 400 错误 "Invalid model"
- 无明显规律，批量模型 (Transcribe V2) 作为可靠降级方案
- 说明 Mistral 实时 API 的**稳定性仍有待提升**

### 与 WhisperUtil 现有 Realtime 模式对比

| 维度 | OpenAI Realtime (当前) | Mistral Voxtral Realtime |
|------|----------------------|-------------------------|
| 协议 | WebSocket | WebSocket |
| 延迟 | ~200ms | 可配置 80ms-2400ms |
| 稳定性 | 成熟稳定 | 间歇性故障报告 |
| 开源 | 否 | Apache 2.0 |
| 本地部署 | 不可能 | 可能 (4B 参数) |

## Part 5: 收费情况

### API 定价

| 模型 | 价格 |
|------|------|
| Voxtral Mini Transcribe V2 (批量) | **$0.003/分钟** |
| Voxtral Realtime (实时) | **$0.006/分钟** |

### 成本对比

| 服务 | 批量转写价格 | 实时转写价格 |
|------|-------------|-------------|
| Mistral Voxtral | $0.003/min | $0.006/min |
| OpenAI Whisper API | $0.006/min | — |
| OpenAI gpt-4o-transcribe | ~$0.006/min | — |
| OpenAI Realtime | — | ~$0.06/min (token计费) |

- Voxtral 批量转写比 OpenAI Whisper **便宜 50%**
- Voxtral 实时转写与 OpenAI Whisper 批量价格持平
- 相比 OpenAI Realtime API（按 token 计费，约 $0.06/min），Voxtral Realtime **便宜约 10 倍**

### 免费额度

- **Experiment 计划**: 免费，仅需手机号验证，无需信用卡
- 包含数小时音频处理额度（具体数字未公布）
- 限制: 免费计划的 API 请求可能被用于训练 Mistral 模型
- 一个手机号只能关联一个 Experiment 计划

### 升级路径

- **Scale 计划**: 按量付费，更高速率限制，前沿模型访问

## Part 6: API 接口设计和集成方式

### 批量转写 API

**端点**: `POST https://api.mistral.ai/v1/audio/transcriptions`

**请求参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| model | string | 是 | 模型 ID，如 `voxtral-mini-latest` |
| file | File | 否 | 上传的音频文件 |
| file_id | string | 否 | 已上传文件的 ID |
| file_url | string | 否 | 音频文件 URL |
| language | string | 否 | 音频语言代码，如 `en` |
| diarize | boolean | 否 | 说话人分离，默认 false |
| temperature | number | 否 | 采样温度 |
| context_bias | array | 否 | 上下文偏置词汇列表 |
| timestamp_granularities | array | 否 | `["segment"]` 或 `["word"]` |
| stream | boolean | 否 | 是否启用 SSE 流式，默认 false |

**响应格式**:

```json
{
  "model": "voxtral-mini-2602",
  "text": "转写文本...",
  "language": "en",
  "segments": [...],
  "usage": {
    "prompt_audio_seconds": 60.0,
    "prompt_tokens": 1000,
    "total_tokens": 1200,
    "completion_tokens": 200
  }
}
```

### 实时转写 API

- 协议: WebSocket
- Python SDK: `pip install mistralai[realtime]`
- 方法: `client.audio.realtime.transcribe_stream()`
- 音频格式: PCM 16-bit LE, 16kHz

### SDK 支持

- Python: 官方 `mistralai` SDK
- TypeScript: 官方 SDK
- HTTP/cURL: REST API
- **Swift: 无官方 SDK**，需自行封装 HTTP/WebSocket 调用

### 与 WhisperUtil 集成考量

WhisperUtil 现有三种模式的接口对比：

| 维度 | OpenAI Cloud | OpenAI Realtime | Mistral Batch | Mistral Realtime |
|------|-------------|-----------------|---------------|-----------------|
| 协议 | HTTP POST | WebSocket | HTTP POST | WebSocket |
| 端点 | `/v1/audio/transcriptions` | WebSocket URL | `/v1/audio/transcriptions` | WebSocket |
| 认证 | Bearer token | Bearer token | Bearer token | Bearer token |
| Swift SDK | 无 (自行封装) | 无 (自行封装) | 无 (自行封装) | 无 (自行封装) |

Mistral 的批量转写 API 与 OpenAI Whisper API 接口**高度相似**（相同端点路径、相似参数），集成工作量相对较小。

## Part 7: 与竞品对比

### STT 精度对比 (WER)

| 模型 | 英语 WER | 多语言 WER | 来源 |
|------|---------|-----------|------|
| Voxtral Small (24B) | 2.1% | 3.8% | WhisperNotes benchmark |
| Voxtral Mini Transcribe V2 | 3.2% | 4.9% | WhisperNotes benchmark |
| Whisper Large v3 | 2.4% | 3.9% | WhisperNotes benchmark |
| GPT-4o Audio | 2.8% | 4.1% | WhisperNotes benchmark |

### 综合对比

| 维度 | Mistral Voxtral | OpenAI Whisper/gpt-4o | WhisperKit (本地) |
|------|----------------|----------------------|------------------|
| 精度 (英语) | 优秀 (2.1-3.2%) | 优秀 (2.4-2.8%) | 良好 |
| 价格 | 低 ($0.003/min) | 中 ($0.006/min) | 免费 |
| 实时流式 | 有 (WebSocket) | 有 (Realtime API) | 有 (本地) |
| 本地部署 | 可能 (4B, Apache 2.0) | 不可能 (API only) | 已支持 |
| 中文支持 | 13 语言含中文 | 57+ 语言含中文 | 依赖模型 |
| Code-switching | 声称支持，未验证 | 有限支持 | 有限 |
| diarization | 支持 (批量模式) | 不支持 | 不支持 |
| API 稳定性 | 有间歇故障报告 | 成熟稳定 | N/A |
| Swift SDK | 无 | 无 | 原生 Swift |

### Mistral 的独特优势

1. **价格**: 批量转写比 OpenAI 便宜 50%
2. **开源权重**: Realtime 模型 Apache 2.0，可本地部署
3. **说话人分离**: 内置 diarization 支持
4. **上下文偏置**: 可自定义领域词汇提升精度
5. **词级时间戳**: 可用于字幕生成

## Part 8: 已知问题和局限性

### 技术限制

1. **实时模式不支持 diarization**: Realtime 模型无法做说话人分离
2. **context_bias 非英语支持为实验性**: 中文等语言的上下文偏置效果未知
3. **timestamp 与 language 参数互斥**: 指定语言时无法同时获取时间戳
4. **语言数量有限**: 仅 13 种语言，远少于 Whisper 的 57+ 种

### 稳定性问题

5. **API 间歇性故障**: VoiceInk 用户报告 Realtime 模型间歇返回 "Invalid model" 错误 (GitHub #533)
6. **产品较新**: Transcribe V2 于 2026-02 发布，仅约 2 个月历史，成熟度不及 OpenAI

### 集成挑战

7. **无 Swift SDK**: 需要自行封装 HTTP 和 WebSocket 调用
8. **需要额外 API Key 管理**: 用户需要同时管理 OpenAI 和 Mistral 两套 API Key
9. **WebSocket 协议差异**: 与 OpenAI Realtime API 的 WebSocket 协议不同，无法复用现有代码

### Code-Switching 不确定性

10. **中英混杂无公开基准**: 官方声称支持但没有 code-switching 专项测试数据
11. **实际效果待验证**: 需要自行测试中英混杂场景的转写质量

---

## Part 9: 补充：跨语言对 Code-Switching 评测数据

### 各服务多语言对 CS 支持矩阵

| 服务 | 支持的 CS 语言对 | 日+英 | 中+日 | 西+英 | 韩+英 | 印地+英 |
|------|-----------------|:-----:|:-----:|:-----:|:-----:|:------:|
| Deepgram Nova-3 | en/es/fr/de/hi/ru/pt/ja/it/nl 共10语互切 | ✅ | ❌ | ✅ | ❌ | ✅ |
| Speechmatics | 专门双语包：cmn+en, ar+en, ms+en, ta+en, fil+en | ❌ | ❌ | ⚠️ 需特殊配置 | ❌ | ❌ |
| Soniox | 宣称 60+ 语言统一模型自动检测 | ❓ 无专项数据 | ❓ | ❓ | ❓ | ❓ |
| Whisper/gpt-4o-transcribe | 理论99语言，无专门CS优化 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| ElevenLabs | 仅优化印度语-英语 | ❌ | ❌ | ❌ | ❌ | ⚠️ |
| **Mistral Voxtral** | **声称13语言切换，无专项数据** | **❓** | **❓** | **❓** | **❓** | **❓** |
| Apple SFSpeechRecognizer | 单语言，不支持CS | ❌ | ❌ | ❌ | ❌ | ❌ |
| Groq (Whisper) | 同 Whisper 模型 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |

**结论：没有一个服务能覆盖所有语言对的 code-switching。** Mistral Voxtral 声称支持 13 种语言间的 CS，其中包含中文和英文，但所有语言对均标记为 ❓（无专项评测数据）。在缺乏公开基准的情况下，无法确认其 CS 实际效果。

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

> 对 Mistral 而言，Voxtral 支持的 13 种语言均在 CS-FLEURS 数据集的覆盖范围内。建议 Mistral 团队或社区在 CS-FLEURS 上发布 Voxtral 的 CS 评测结果，以便开发者做出有据可依的选择。Voxtral Realtime 的开源属性（Apache 2.0）也使社区自行评测成为可能。

### 学术界核心趋势

- 参数高效微调(LoRA/Adapter) + 语言识别引导解码 + 合成数据增强是三大主线
- 微调后 MER 可相对降 4-7%

---

## 集成建议

### 是否值得集成？

**短期 (1-3 个月): 暂不建议**
- API 稳定性未经充分验证
- 中英混杂效果未知
- 增加维护复杂度 (额外 API Key、额外服务层)

**中期 (3-6 个月): 可考虑作为备选方案**
- 关注 Mistral API 稳定性改善
- 等待更多第三方中文/code-switching 基准测试
- 如果 OpenAI 涨价，Voxtral 的价格优势更明显

**长期: 本地部署值得关注**
- Voxtral Realtime 4B 参数 + Apache 2.0 许可
- 可能成为 WhisperKit 之外的另一个本地方案
- 社区已有 MLX、Pure C 等本地推理实现
- 对 macOS 本地部署潜力较大

### 如果决定集成，优先级建议

1. **优先**: Voxtral Batch API (与现有 Cloud 模式接口相似，工作量最小)
2. **其次**: Voxtral Realtime WebSocket (需新建 Service 层)
3. **远期**: 本地 Voxtral 部署 (依赖社区 MLX/CoreML 转换成熟度)
