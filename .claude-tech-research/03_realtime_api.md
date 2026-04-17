# OpenAI Realtime API 研究报告

## 摘要

OpenAI Realtime API 已于 2025 年 8 月 28 日正式 GA（General Availability），支持 WebSocket 和 WebRTC 两种连接方式，提供对话模式和转录专用模式（intent=transcription）。转录专用模式使用 `transcription_session.update` 配置，支持 gpt-4o-transcribe、gpt-4o-mini-transcribe 和 whisper-1 三种模型。最新的 gpt-4o-mini-transcribe-2025-12-15 快照在准确率和抗幻觉方面有显著提升，OpenAI 官方推荐优先使用。本项目当前实现基本正确，但存在模型选择、VAD 类型（可考虑 semantic_vad）、以及 delta 事件实际行为与预期不完全一致等需要关注的点。

## 详细报告

### 1. Realtime API 概述与当前状态

**GA 状态**：Realtime API 于 2025 年 8 月 28 日正式 GA，从 beta 迁移到 GA 接口有 breaking changes。Beta 接口将最终弃用。

**两种使用模式**：
- **对话模式**（Conversations）：语音对话，支持 speech-to-speech，使用 `gpt-realtime` 模型
- **转录专用模式**（Transcription）：仅做语音转文字，不产生 AI 回复，使用 `intent=transcription` 参数连接

**会话时长**：单个会话最长 60 分钟（从之前的 30 分钟延长）。

**GA vs Beta 变化**：
- 温度参数（temperature）在 GA 接口中已移除
- GA 支持图片输入、异步函数调用、音频 token 转文本
- GA 支持 EU 数据驻留（仅限特定模型快照）
- Token 窗口：gpt-realtime 为 32,768 总 tokens；响应最多 4,096，留给输入上下文 28,672

### 2. WebSocket 协议细节

**连接 URL**：
- 对话模式：`wss://api.openai.com/v1/realtime?model=gpt-realtime`
- 转录专用模式：`wss://api.openai.com/v1/realtime?intent=transcription`

**认证方式**：
- 服务端 WebSocket：通过 HTTP 头 `Authorization: Bearer <API_KEY>`
- Beta 头：`OpenAI-Beta: realtime=v1`（beta 期间必须，GA 后可能变化）
- 浏览器/客户端：推荐使用 WebRTC + 临时 token，避免暴露 API key
- 子协议方式：`openai-insecure-api-key.<API_KEY>`（不推荐用于生产）

**注意事项**：
- `Authorization` 头的 `Bearer` 必须大写 B，大小写敏感
- WebSocket 推荐仅用于服务端到服务端通信
- 可选传递 Organization 和 Project 头

**事件格式**：所有事件均为 JSON 序列化的文本字符串，通过 WebSocket 传输。

**Keep-alive**：建议每 15-25 秒发送 ping，连续 2 次 pong 超时应重连。

### 3. 转录专用模式配置

**连接**：使用 `wss://api.openai.com/v1/realtime?intent=transcription`

**可用模型**：

| 模型 | 特点 | 推荐度 |
|------|------|--------|
| `gpt-4o-mini-transcribe` | 最新推荐，准确率高，幻觉少 ~90%（vs Whisper v2），中文表现强 | **推荐** |
| `gpt-4o-transcribe` | 准确率高（WER 2.46%），但幻觉多于 mini 版 | 次选 |
| `whisper-1` | 经典模型，delta 事件行为不同（见下） | 兼容用 |

**会话配置事件**：`transcription_session.update`

```json
{
  "type": "transcription_session.update",
  "session": {
    "input_audio_format": "pcm16",
    "input_audio_transcription": {
      "model": "gpt-4o-mini-transcribe",
      "language": "zh"
    },
    "turn_detection": {
      "type": "server_vad",
      "threshold": 0.5,
      "prefix_padding_ms": 300,
      "silence_duration_ms": 500
    }
  }
}
```

**服务器事件流（转录模式）**：

| 事件类型 | 说明 |
|---------|------|
| `transcription_session.created` | 连接成功，此时发送配置 |
| `transcription_session.updated` | 配置完成，可开始发送音频 |
| `conversation.item.input_audio_transcription.delta` | 转录增量（gpt-4o 系列为流式增量，whisper-1 为整段文本） |
| `conversation.item.input_audio_transcription.completed` | 一段话转录完成 |
| `input_audio_buffer.speech_started` | VAD 检测到语音开始 |
| `input_audio_buffer.speech_stopped` | VAD 检测到语音结束 |
| `input_audio_buffer.committed` | 音频缓冲区已提交 |
| `error` | API 错误 |

**重要行为差异**：
- `gpt-4o-transcribe` / `gpt-4o-mini-transcribe`：delta 事件包含逐词增量
- `whisper-1`：delta 事件包含整段文本（与 completed 事件相同内容）

**Logprobs / 置信度**：可通过 `include` 属性请求 `item.input_audio_transcription.logprobs`，用于计算转录置信度分数。

### 4. Server VAD 参数与行为

**两种 VAD 类型**：

#### server_vad（默认）
基于静音时长自动分段，适合大多数场景。

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `threshold` | 激活阈值（0-1），越高需要越响的声音 | 0.5 |
| `prefix_padding_ms` | 语音检测前保留的音频（毫秒） | 300 |
| `silence_duration_ms` | 静音多久判定语音结束（毫秒），越短分段越快 | 500 |
| `interrupt_response` | 是否允许用户打断（对话模式用） | -- |
| `create_response` | 是否自动生成回复（对话模式用） | -- |
| `idle_timeout_ms` | 空闲超时，触发 `input_audio_buffer.timeout_triggered` | -- |

#### semantic_vad（GA 新增）
基于语义理解判断用户是否说完，更自然但延迟稍高。

| 参数 | 说明 |
|------|------|
| `eagerness` | low / medium / high，最大超时分别为 8s / 4s / 2s |

semantic_vad 使用语义分类器判断用户是否完成发言。例如用户说 "嗯..." 会等待更长时间，而明确的陈述会快速结束。适合对话场景，但转录场景可能增加延迟。

**注意**：社区报告 semantic_vad 存在一些稳定性问题（不工作或行为不一致），建议在转录模式中优先使用 server_vad。

#### 无 VAD（手动控制）
将 `turn_detection` 设为 `null`，由客户端通过 `input_audio_buffer.commit` 手动控制分段。

### 5. 音频格式与性能

**输入音频格式**：
- `pcm16`：16-bit PCM，24kHz 采样率，单声道，小端字节序（**唯一支持的 PCM 格式**）
- 通过 `input_audio_buffer.append` 事件发送，音频数据需 base64 编码

**音频块大小**：
- base64 编码后的帧应保持在 15-50 KB 范围
- 过大的块会触发错误

**延迟表现**：
- Realtime API 平均响应延迟约 232ms（官方数据）
- 比 HTTP Whisper API（500ms-1s+）快得多
- 使用 Opus 格式（音频输出）、启用 server VAD、选择就近区域可降低 P95 延迟约 18%

**实际行为**（社区反馈）：
- 转录 delta 实际上在用户**停止说话后**才到达，而非实时逐词
- 实际事件流为：speech_started -> speech_stopped -> delta(s) -> completed
- 频繁手动 commit 会降低准确率
- 这意味着 "实时" 更多指低延迟返回，而非严格意义上的边说边出字

### 6. 定价分析

#### 转录专用模式（intent=transcription）定价

使用转录模型的独立费率计费，与对话模式费率不同：

| 模型 | 输入 (per 1M tokens) | 输出 (per 1M tokens) | 预估每分钟 |
|------|---------------------|---------------------|-----------|
| `gpt-4o-transcribe` | $2.50 | $10.00 | ~$0.006 |
| `gpt-4o-mini-transcribe` | $1.25 | $5.00 | ~$0.003 |

#### 对话模式（conversation）定价

| 模型 | 音频输入 | 缓存输入 | 音频输出 | 文本输入 | 文本输出 |
|------|---------|---------|---------|---------|---------|
| `gpt-realtime-1.5` | $32/1M | $0.40/1M | $64/1M | $4/1M | $16/1M |
| `gpt-realtime-mini` | $10/1M | $0.30/1M | $20/1M | $0.60/1M | $2.40/1M |

#### Token 计算方式
- 用户音频：1 token / 100ms（1 分钟 = 600 tokens）
- AI 音频输出：1 token / 50ms（1 分钟 = 1200 tokens）

#### 成本优化
- VAD 会过滤静音，静音不计入 token
- Prompt caching 自动生效，可大幅降低多轮会话成本
- 设置 `retention_ratio: 0.8` 可优化缓存命中率
- 无连接费或带宽费

#### 与 HTTP API 对比成本
- HTTP `gpt-4o-transcribe`：$0.006/分钟
- HTTP `whisper-1`：$0.006/分钟
- Realtime 转录模式：$0.003-$0.006/分钟（取决于模型）
- **结论**：转录专用模式成本与 HTTP API 相当，甚至更低（使用 mini 模型时）

### 7. 与 HTTP API 对比

| 维度 | Realtime API（转录模式） | HTTP Whisper API |
|------|------------------------|------------------|
| **延迟** | 极低（~232ms），边录边传 | 较高（500ms-1s+），录完再传 |
| **流式输出** | 支持 delta 增量（VAD 分段后） | 不支持，一次性返回 |
| **音频格式** | 仅 PCM16 24kHz | 支持多种格式（m4a, wav, mp3 等） |
| **最大音频** | 会话 60 分钟 | 单文件 25MB |
| **成本** | ~$0.003-0.006/分钟 | ~$0.006/分钟 |
| **连接复杂度** | 高（WebSocket 状态管理） | 低（单次 HTTP POST） |
| **可靠性** | 需处理断连、重连 | HTTP 天然可靠 |
| **离线友好** | 否，需持续连接 | 可录音后上传 |
| **VAD** | 服务端 VAD，自动分段 | 无，需客户端实现 |
| **压缩** | 不支持压缩传输（raw PCM） | 支持 AAC/M4A 压缩 |
| **带宽** | PCM 24kHz 约 48KB/s | AAC 压缩后约 3KB/s |

**适用场景建议**：
- **Realtime API**：需要即时反馈的场景（实时字幕、对话式交互、打字即显）
- **HTTP API**：录音后批量处理、带宽受限环境、需要高可靠性的场景

### 8. 已知限制与 Quirks

#### 文档与实际行为差异

1. **Delta 不是真正实时的**：转录 delta 在 VAD 检测到语音结束后才返回，而非边说边出。事件流实际为 speech_started -> speech_stopped -> deltas -> completed。这是最容易被误解的行为。

2. **频繁 commit 降低准确率**：有开发者尝试通过频繁发送 `input_audio_buffer.commit` 来获得更实时的结果，但这会导致准确率明显下降。

#### 技术限制

3. **音频块大小限制**：base64 编码的音频帧应保持在 15-50KB，过大会报错。

4. **仅支持 PCM16 24kHz**：不支持其他采样率或格式作为输入，带宽消耗较大。

5. **指令长度限制**（对话模式）：system instructions 超过约 750 字符可能导致模型混乱。

6. **Token 上限**：即使消息很短，有时也会触发 4,096 output token 限制。

7. **WebSocket 需要 keep-alive**：每 15-25 秒发送一次 ping，否则可能断连。

#### 稳定性问题

8. **semantic_vad 不稳定**：社区多次报告 semantic_vad 不工作或行为不一致。

9. **自我中断**（对话模式）：模型可能"听到自己说话"并误认为是用户输入，导致无限循环。

10. **指令遵循偏差**：GA 模型对指令更严格（字面执行），需仔细审查 prompt。

11. **OpenAI-Beta 头格式**：必须精确为 `realtime=v1`，格式错误会导致连接失败。

12. **beta -> GA 迁移**：`session.update` 变为 `transcription_session.update`（转录模式），`input_audio_format` 字段位置和格式变化，需要注意。

### 9. 项目当前实现分析与建议

#### 当前实现正确的部分

1. **WebSocket URL**：使用 `wss://api.openai.com/v1/realtime?intent=transcription`，正确使用了转录专用模式
2. **认证头**：`Authorization: Bearer` + `OpenAI-Beta: realtime=v1`，格式正确
3. **事件配置**：使用 `transcription_session.update`，正确的 GA API 格式
4. **音频格式**：指定 `pcm16`，正确
5. **VAD 配置**：使用 `server_vad`，参数合理（threshold: 0.5, prefix_padding: 300ms, silence: 500ms）
6. **事件处理**：正确处理了所有关键事件类型（session.created/updated, delta, completed, speech_started/stopped, error）
7. **采样率**：Constants.swift 中 `realtimeSampleRate = 24000`，正确

#### 建议改进

1. **模型更新（推荐）**：
   - 当前使用 `EngineeringOptions.whisperModel`（即 `gpt-4o-transcribe`）
   - OpenAI 官方推荐使用 `gpt-4o-mini-transcribe`（更准确、幻觉更少、成本减半）
   - 特别是最新快照 `gpt-4o-mini-transcribe-2025-12-15` 在中文方面有显著提升
   - 建议在 `EngineeringOptions` 中为 Realtime 模式添加独立的模型配置项，与 HTTP API 的 `whisperModel` 分开

2. **考虑添加 WebSocket 心跳**：
   - 当前实现没有 ping/pong 机制
   - 长时间录音（静音段较多）可能导致连接被服务器断开
   - 建议每 15-25 秒发送一次 ping

3. **重连机制**：
   - 当前断连后直接报错
   - 建议添加自动重连逻辑（带指数退避），特别是对于长录音场景

4. **idle_timeout_ms**：
   - 当前未设置 idle_timeout_ms
   - 对于转录场景，建议设置一个合理值（如 10000ms），避免长时间静音后连接资源浪费

5. **Delta 行为预期管理**：
   - 当前 `realtimeDeltaMode = true` 期望逐词实时输出
   - 实际行为是 VAD 分段后才返回 delta，并非边说边出
   - 代码逻辑本身没有问题（正确累积 delta），但 UX 层面需要理解这一行为：用户说完一段话后才会看到文字出现，而非实时打字效果
   - 这也意味着 `silence_duration_ms: 500` 的选择是关键——它决定了多快返回一段转录

6. **音频块大小控制**：
   - 当前 `sendAudioChunk` 直接发送传入的数据
   - 建议添加大小检查，确保 base64 编码后不超过 50KB（约 37KB raw PCM = ~0.77秒 24kHz 16-bit）

7. **错误恢复**：
   - `parseJSONMessage` 中 error 事件仅通知上层，未区分可恢复/不可恢复错误
   - 某些错误（如 rate limit）可以通过重试恢复
   - 建议根据错误类型（error code/type）做差异化处理

8. **带宽考虑**：
   - PCM16 24kHz 约 48KB/s（约 2.88MB/分钟）
   - 对比 HTTP API 使用 AAC 压缩（~3KB/s）高出约 16 倍
   - 在移动网络或弱网环境下可能成为瓶颈
   - 这是 Realtime API 的固有限制，无法通过代码解决

## 来源 (Sources)

- [Realtime transcription | OpenAI API](https://platform.openai.com/docs/guides/realtime-transcription) -- 官方转录模式文档
- [Realtime API | OpenAI API](https://platform.openai.com/docs/guides/realtime) -- 官方 Realtime API 总览
- [Realtime API with WebSocket | OpenAI API](https://developers.openai.com/api/docs/guides/realtime-websocket) -- WebSocket 连接指南
- [Voice activity detection (VAD) | OpenAI API](https://platform.openai.com/docs/guides/realtime-vad) -- VAD 参数文档
- [Managing costs | OpenAI API](https://developers.openai.com/api/docs/guides/realtime-costs) -- 成本管理指南
- [Pricing | OpenAI API](https://developers.openai.com/api/docs/pricing) -- 官方定价页
- [Developer notes on the Realtime API | OpenAI Developers](https://developers.openai.com/blog/realtime-api) -- GA 迁移和开发者注意事项
- [Updates for developers building with voice | OpenAI Developers](https://developers.openai.com/blog/updates-audio-models) -- 最新模型快照更新
- [Realtime streaming transcription - OpenAI Developer Community](https://community.openai.com/t/realtime-streaming-transcription/1371205) -- 社区反馈：delta 事件实际行为
- [Realtime API issues - good practices - OpenAI Developer Community](https://community.openai.com/t/realtime-api-issues-good-practices/1031546) -- 社区最佳实践
- [Realtime API vs Whisper vs TTS API | eesel.ai](https://www.eesel.ai/blog/realtime-api-vs-whisper-vs-tts-api) -- API 对比分析
- [OpenAI Realtime API Pricing 2025 | Skywork AI](https://skywork.ai/blog/agent/openai-realtime-api-pricing-2025-cost-calculator/) -- 定价计算器
- [Comparing Speech-to-Text Methods | OpenAI Cookbook](https://cookbook.openai.com/examples/speech_transcription_methods) -- 转录方法对比
- [Changelog | OpenAI API](https://developers.openai.com/api/docs/changelog) -- API 变更日志
