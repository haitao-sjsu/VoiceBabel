# 翻译功能代码审查报告

## 审查范围

- `Services/ServiceCloudOpenAI.swift` — translate()、translateTwoStep()、chatTranslate()
- `RecordingController.swift` — translateAudio()、stopTranslationRecording()、相关路由逻辑
- `Config/EngineeringOptions.swift` — translationMethod、translationSourceLanguageFallback
- `Config/SettingsStore.swift` — translationTargetLanguage
- `Config/Config.swift` — translationMethod 传递
- `UI/SettingsView.swift` — Translation section

---

## 已确认的 Bug

### Bug 1: chatTranslate() 目标语言硬编码为英语

**文件**: `Services/ServiceCloudOpenAI.swift` 第 140 行

```swift
"content": "You are a translator. Translate the following text to English. Output ONLY the translation, nothing else."
```

**问题**: prompt 中 "to English" 是硬编码的，完全忽略了 `SettingsStore.translationTargetLanguage` 用户设置。用户在设置面板选择翻译目标语言为中文/日语/法语等，两步法仍然只输出英文。

**影响**: SettingsView 中的 Translation > Output Language 选择器（支持 en/zh/ja/ko/fr/de/es 七种语言）形同虚设，用户改了设置但没有任何效果。

**修复建议**: chatTranslate() 需要接收目标语言参数，由 RecordingController 从 SettingsStore.translationTargetLanguage 读取后传入。prompt 改为动态插值：

```swift
private func chatTranslate(text: String, targetLanguage: String, completion: ...)
// prompt: "Translate the following text to \(languageDisplayName). Output ONLY the translation, nothing else."
```

### Bug 2: translate() 直接翻译法同样只支持英语

**文件**: `Services/ServiceCloudOpenAI.swift` 第 83-94 行

**问题**: Whisper `/v1/audio/translations` API 本身只支持翻译为英语（这是 OpenAI API 的限制），但代码没有在 UI 层做任何提示。当用户选择 whisper 直接翻译法且目标语言非英语时，实际输出仍为英语，违背用户期望。

**修复建议**:
- 当 `translationMethod == "whisper"` 时，UI 应禁用或隐藏目标语言选择器，并显示"仅支持英语"提示
- 或者：当目标语言非英语时，自动降级为 two-step 方法

### Bug 3: translationSourceLanguageFallback 未被使用

**文件**: `Config/EngineeringOptions.swift` 第 165 行

```swift
static let translationSourceLanguageFallback = "zh"
```

**问题**: 这个常量定义了但从未被任何代码引用。sendRequest() 中的回退逻辑（第 267 行）硬编码了 `"zh"`：

```swift
let effectiveLanguage = language.isEmpty ? "zh" : language
```

**修复建议**: 将硬编码的 `"zh"` 替换为 `EngineeringOptions.translationSourceLanguageFallback`。

---

## 代码质量

### 1. chatTranslate() 与 ServiceTextCleanup 高度重复

chatTranslate()（ServiceCloudOpenAI.swift 第 123-195 行）和 ServiceTextCleanup.cleanup()（ServiceTextCleanup.swift 第 102-195 行）几乎是同一个方法的复制粘贴：

- 相同的 URL 构建（`EngineeringOptions.chatCompletionsURL`）
- 相同的 Authorization header 设置
- 相同的 JSON payload 结构（model, messages）
- 相同的 `URLSession.shared.dataTask` 回调解析模式
- 相同的 Chat Completions JSON 响应解析代码（choices[0].message.content）

**建议**: 抽取一个私有的通用 Chat Completions 调用方法，或者将 chatTranslate 挪到一个独立的翻译 Service 中复用公共的 HTTP 层。

### 2. chatTranslate() 使用 URLSession.shared，与 sendRequest() 不一致

`sendRequest()` 创建自定义 URLSessionConfiguration 设置动态超时，用完后调用 `session.finishTasksAndInvalidate()`。而 chatTranslate() 直接使用 `URLSession.shared`，超时只设了 `apiProcessingTimeoutMin`（5 秒），没有根据文本长度动态调整。

对于长文本翻译，5 秒超时可能不够。

**建议**: chatTranslate() 应该使用与 sendRequest() 一致的自定义 session 模式，或至少使用合理的超时值。

### 3. 魔法字符串：翻译方法标识

`config.translationMethod` 使用字符串 `"two-step"` 和 `"whisper"` 进行比较（RecordingController.swift 第 537 行）：

```swift
if config.translationMethod == "two-step" {
```

**建议**: 定义为枚举类型，编译期检查，避免拼写错误。

### 4. 模型名称硬编码

chatTranslate() 中 `"gpt-4o-mini"` 硬编码（第 137 行），translate() 中 `"whisper-1"` 硬编码（第 89 行）。这些应该提升到 EngineeringOptions，与其他模型配置保持一致。

---

## 错误处理

### 1. chatTranslate() 缺少重试机制

两步法的第二步（GPT 翻译）失败时直接向上传播错误，没有重试。考虑到第一步（转录）已成功且消耗了 API 调用，第二步失败意味着用户需要重新录音重新走完整流程。

**建议**: 至少对网络错误进行一次重试，或者缓存第一步的转录结果以支持只重试第二步。

### 2. 两步法第一步失败时无降级策略

translateTwoStep() 中，如果 transcribe() 失败（网络错误），直接 `completion(.failure(error))` 返回。但此时可以尝试降级为 whisper 直接翻译法。

### 3. chatTranslate() 的错误类型复用 WhisperError

chatTranslate() 使用 `WhisperError.networkError`、`WhisperError.invalidResponse` 等（本质上是 Whisper API 的错误类型），但它调用的是 Chat Completions API。错误信息可能误导调试。

---

## 架构设计

### 1. 翻译功能寄生在 ServiceCloudOpenAI 中

ServiceCloudOpenAI 的主要职责是 Whisper 转录，翻译功能（translate、translateTwoStep、chatTranslate）是附加的。特别是 chatTranslate() 调用的是 Chat Completions API，与 Whisper 无关。

**建议**: 将翻译功能抽取为独立的 `ServiceTranslation`，接收 apiKey 和 targetLanguage，内部封装两种翻译策略。这样也便于未来接入其他翻译引擎。

### 2. 翻译模式强制走 Cloud，无 fallback

RecordingController.startRecording() 中（第 244-249 行），当 `currentMode == .translate` 时，无论 `currentApiMode` 是什么，都走 `startNonStreamingRecording()`，然后在 stopRecording() 中走 stopTranslationRecording()。翻译始终使用 `whisperService`（Cloud HTTP），不支持 Local 或 Realtime API 模式。

这个设计本身是合理的（翻译需要 Cloud API），但缺少以下处理：
- 用户在 Local 模式下触发翻译时，没有明确提示"翻译将使用 Cloud API"
- 翻译的 Cloud 调用失败时，没有像转录那样的 Local fallback 机制（虽然 Local 翻译难以实现，但至少可以 fallback 到"先本地转录 + Cloud GPT 翻译"）

### 3. translationTargetLanguage 未传递到翻译调用链

数据流断裂：`SettingsStore.translationTargetLanguage` -> （断裂） -> `chatTranslate()` 硬编码英语

`translationTargetLanguage` 没有出现在 Config 中，也没有通过 Combine 订阅传递到 RecordingController，也没有作为参数传给 ServiceCloudOpenAI。这不仅是一个 bug，更是一个数据流设计缺陷。

**修复路径**: SettingsStore.translationTargetLanguage -> (Combine 订阅 or 直接读取) -> RecordingController.translateAudio() -> ServiceCloudOpenAI.translateTwoStep(targetLanguage:) -> chatTranslate(targetLanguage:)

---

## 安全性

### API Key 处理：合格

- API Key 通过构造函数注入 ServiceCloudOpenAI，存储在 Keychain，不在日志中输出
- Bearer token 通过 HTTPS 传输

### 用户音频数据

- 音频数据通过 HTTPS multipart 上传，传输安全
- 两步法中，转录后的文本（可能包含敏感信息）通过 Chat Completions API 再次发送到 OpenAI，用户可能不清楚文本被二次发送

---

## 性能

### 两步法延迟

两步法是串行的：先完成转录，再发起 GPT 翻译。总延迟 = 转录延迟 + 翻译延迟。

**优化空间有限**: 两步法本质上是串行依赖（第二步需要第一步的结果），无法并行化。但可以考虑：
- 使用 streaming 模式调用 Chat Completions API，边生成边输出翻译结果，降低感知延迟
- 对短文本（< 100 字），翻译延迟本身很小（< 1 秒），优化价值不大

### chatTranslate() 超时过短

使用 `apiProcessingTimeoutMin`（5 秒）作为超时，对于长文本翻译可能不够。sendRequest() 中根据音频时长动态计算超时的做法更合理。

---

## 可扩展性

### 接入其他翻译引擎的难度

当前翻译逻辑分散在 ServiceCloudOpenAI 和 RecordingController 中，如果要接入 DeepL、Google Translate 或本地翻译引擎：

1. **无翻译协议/接口**: 没有 `TranslationService` protocol，无法通过依赖注入替换翻译后端
2. **翻译策略硬编码**: `translationMethod` 只支持 `"whisper"` 和 `"two-step"` 两种，添加新引擎需要修改 RecordingController 的 if-else 逻辑
3. **chatTranslate 与 Cloud 服务紧耦合**: GPT 翻译逻辑嵌在 ServiceCloudOpenAI 内部，不可替换

**建议架构**:

```
protocol TranslationService {
    func translate(audioData: Data, format: AudioFormat, targetLanguage: String,
                   completion: @escaping (Result<String, Error>) -> Void)
}

class TranslationWhisperDirect: TranslationService { ... }
class TranslationTwoStep: TranslationService { ... }
class TranslationDeepL: TranslationService { ... }  // 未来
```

RecordingController 只持有 `TranslationService` 引用，由 AppDelegate 根据配置注入具体实现。

---

## 测试覆盖

当前项目没有测试文件。翻译功能需要补充的关键测试：

1. **chatTranslate() 单元测试**: Mock URLSession，验证请求 payload 结构、目标语言参数、JSON 解析
2. **translateTwoStep() 集成测试**: 验证两步串联的错误传播和空文本处理
3. **translateAudio() 路由测试**: 验证 translationMethod 配置正确路由到对应方法
4. **translationTargetLanguage 端到端测试**: 验证设置面板的语言选择能传递到实际 API 调用（当前此测试一定失败，因为存在 Bug 1）
5. **错误场景测试**: 网络超时、API 429 限流、空音频数据、空转录结果

---

## 与项目其他 Service 的一致性

### 一致的部分
- 错误类型定义模式（嵌套 enum + LocalizedError）与 ServiceTextCleanup 一致
- 回调模式（Result<String, Error> completion handler）全项目统一
- API Key 注入方式一致（构造函数参数）

### 不一致的部分
- chatTranslate() 使用 `URLSession.shared`，而项目中其他网络调用（sendRequest、ServiceTextCleanup）都注意了超时管理
- ServiceTextCleanup 在网络错误时有日志记录（`Log.e`），chatTranslate() 没有
- ServiceTextCleanup 设置了 `temperature: 0.3`，chatTranslate() 使用默认 temperature（1.0），翻译结果可能不够稳定

---

## 总结

翻译功能整体可用但存在明显缺陷。最核心的问题是 **目标语言硬编码**，导致用户设置无效。架构上翻译逻辑寄生在转录 Service 中，耦合较紧，不利于未来扩展。代码重复（chatTranslate 与 ServiceTextCleanup）和不一致（URLSession 使用、temperature、日志）需要清理。

### 优先级排序

| 优先级 | 问题 | 类型 |
|--------|------|------|
| P0 | chatTranslate() 目标语言硬编码 | Bug |
| P0 | translationTargetLanguage 数据流断裂 | Bug |
| P1 | chatTranslate() 超时仅 5 秒 | 可靠性 |
| P1 | chatTranslate() 缺少 temperature 设置 | 稳定性 |
| P1 | chatTranslate() 缺少日志记录 | 可观测性 |
| P2 | translationSourceLanguageFallback 未使用 | 死代码 |
| P2 | 翻译方法使用魔法字符串 | 代码质量 |
| P2 | 模型名称硬编码 | 代码质量 |
| P2 | chatTranslate 与 ServiceTextCleanup 代码重复 | 代码质量 |
| P3 | 翻译功能抽取为独立 Service | 架构 |
| P3 | 定义 TranslationService protocol | 可扩展性 |
| P3 | 补充单元测试 | 测试 |
