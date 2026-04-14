# Services 层架构改进建议

## 已完成的清理

1. **统一文件头注释** — 四个 Service 文件均添加了结构化中文头注释（文件名、描述、职责、依赖、架构角色）
2. **移除死代码** — ServiceLocalWhisper 中未使用的 `onTranscriptionComplete` / `onError` 回调属性（遗留自 callback 时代，现已使用 async/await）
3. **移除死代码** — ServiceRealtimeOpenAI 中 `RealtimeError.connectionFailed` 和 `.notConnected`（定义但从未抛出）
4. **简化冗余模式** — ServiceCloudOpenAI 中两处 `if let ... else` 错误消息构造改为 `??` 运算符

## 待改进项

### 1. 重复的 Chat Completions API 调用模式

`ServiceCloudOpenAI.chatTranslate()` 和 `ServiceTextCleanup.cleanup()` 包含几乎相同的代码结构：
- 构造 URLRequest + JSON payload
- 发送 dataTask
- 解析 `choices[0].message.content`
- 错误处理

**建议**：抽取共享的 `ChatCompletionsClient` 或在 ServiceCloudOpenAI 中提供通用的 `chatCompletion(systemPrompt:userContent:)` 方法，ServiceTextCleanup 调用它而非自行实现。

### 2. 重复的超时计算公式

两处独立实现了相同的超时计算逻辑：
- `ServiceCloudOpenAI.calculateProcessingTimeout()` — 封装为方法
- `ServiceTextCleanup.cleanup()` 内联计算 — `min(max(minutes * 10, min), max)`

**建议**：将超时计算移入 `Constants` 作为静态方法 `Constants.dynamicTimeout(audioDuration:)`，消除重复。

### 3. 异步模式不一致

| 服务 | 异步模式 |
|------|---------|
| ServiceLocalWhisper | async/await (Swift Concurrency) |
| ServiceCloudOpenAI | callback closure (`Result<String, Error>`) |
| ServiceTextCleanup | callback closure (`Result<String, Error>`) |
| ServiceRealtimeOpenAI | callback closure (streaming, 合理) |

**建议**：将 ServiceCloudOpenAI 和 ServiceTextCleanup 迁移到 async/await。ServiceRealtimeOpenAI 因流式特性保持回调模式合理。迁移后 RecordingController 中的嵌套回调可简化为线性 async 流程。

### 4. 错误枚举冗余

三个服务定义了几乎相同的错误类型：
- `WhisperError` — networkError, invalidResponse, noData, apiError, decodingError
- `CleanupError` — invalidResponse, noData, apiError, decodingError
- `RealtimeError` — invalidURL, apiError

**建议**：统一为 `ServiceError` 枚举，各服务共享。差异化的 case（如 `invalidURL`）可保留为特定 case。减少枚举定义数量，统一错误处理逻辑。

### 5. 优先级排序

| 优先级 | 改进项 | 收益 | 工作量 |
|--------|--------|------|--------|
| P1 | 超时计算提取到 Constants | 消除重复，一处修改 | 小 |
| P2 | 统一错误枚举 | 减少样板代码，统一错误处理 | 中 |
| P2 | 抽取 Chat Completions 客户端 | 消除重复，便于添加新 GPT 调用 | 中 |
| P3 | HTTP 服务迁移 async/await | 简化 RecordingController 调度逻辑 | 大 |
