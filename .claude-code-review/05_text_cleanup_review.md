# 文本优化（TextCleanup）功能代码审查报告

## 审查范围

- `Services/ServiceTextCleanup.swift` — 核心实现，GPT-4o-mini 文本润色服务
- `RecordingController.swift` — outputText() 调用 text cleanup 的逻辑，Realtime 模式特殊处理
- `Config/EngineeringOptions.swift` — chatCompletionsURL、超时参数
- `Config/SettingsStore.swift` — textCleanupMode 用户设置持久化
- `Config/Config.swift` — textCleanupMode 配置传递
- `Config/UserSettings.swift` — textCleanupMode 默认值
- `Services/ServiceCloudOpenAI.swift` — chatTranslate() 对比参照

---

## 已确认的 Bug

### Bug 1: 模型硬编码为即将退役的 gpt-4o-mini

**文件**: `Services/ServiceTextCleanup.swift` 第 126 行

```swift
"model": "gpt-4o-mini",
```

**问题**: 模型名硬编码在 cleanup() 方法内部，未提升到 EngineeringOptions。gpt-4o-mini 已宣布即将退役，届时文本优化功能将完全失效，且修改需要改动业务代码而非配置文件。

**对比**: 转录模型 `whisperModel` 已正确定义在 EngineeringOptions（第 109 行），文本优化模型应保持一致。

**修复建议**: 在 EngineeringOptions 中添加 `textCleanupModel` 常量，cleanup() 引用该常量。

### Bug 2: Realtime 模式 delta 输出的错误抑制时机

**文件**: `RecordingController.swift` 第 120-137 行

```swift
realtimeService.onTranscriptionDelta = { [weak self] (delta: String) in
    guard let self = self else { return }
    guard EngineeringOptions.realtimeDeltaMode else { return }
    if self.textCleanupMode == .off {
        self.textInputter.inputTextRaw(delta)
    }
    // 当 textCleanupMode != .off 时，delta 被静默丢弃，无任何用户反馈
}
realtimeService.onTranscriptionComplete = { [weak self] (text: String) in
    // ...
    if self.textCleanupMode != .off {
        self.outputText(trimmedText, action: ...)  // 走 cleanup 流程
    } else {
        self.onTranscriptionResult?(trimmedText)   // 仅通知 UI，不再 inputText
    }
}
```

**问题 1**: 开启文本优化时，delta 被完全丢弃但没有任何用户提示（如状态栏显示"处理中..."），用户看到的是长时间无输出，直到 segment 完成后才出现优化文本。体验上是"沉默等待"。

**问题 2**: `textCleanupMode` 是 `var` 属性，在 Realtime 录音期间用户可以通过设置面板实时切换。如果用户录音中途从 off 切到 neutral，已输出的 delta 文本无法撤回，后续 segment 会走 cleanup 流程，导致输出格式不一致（前半段原始文本 + 后半段优化文本混合）。

**问题 3**: `onTranscriptionComplete` 中 `textCleanupMode == .off` 分支只调用了 `onTranscriptionResult?()` 通知 UI，但**没有调用 `textInputter.inputText()`**，也没有调用 `handleAutoSend()`。这意味着在 Realtime 模式 + cleanup off 的情况下，文本通过 delta 逐词输出，segment 完成时只更新 UI 状态，不重复输出完整文本——这个行为是**正确的**（因为 delta 已经输出了文本）。但缺少注释说明这一设计意图，容易被误读为遗漏。

**修复建议**:
- 开启文本优化时，在 delta 到达时更新状态栏显示 "Transcribing..."，让用户知道系统在工作
- 考虑在录音期间锁定 textCleanupMode 变更，或至少在设置面板显示"录音中无法切换"
- 在 `onTranscriptionComplete` 的 off 分支添加注释说明为何不调用 inputText

---

## 代码质量

### 1. TextCleanupMode 枚举放置位置不够理想

**文件**: `Services/ServiceTextCleanup.swift` 第 28-47 行

`TextCleanupMode` 枚举定义在 Service 文件中，但它被 RecordingController、SettingsView、AppDelegate、Config 广泛使用。从依赖方向看，它更适合放在 Config/ 目录（如单独的 `TextCleanupMode.swift` 或 `Config/Types.swift`），避免 Config 层反向依赖 Services 层。

当前项目规模下这不是严重问题，但随着枚举增多会产生循环依赖风险。

### 2. `TextCleanupMode.from()` 与 `init(rawValue:)` 功能重复

**文件**: `Services/ServiceTextCleanup.swift` 第 44-46 行

```swift
static func from(_ string: String) -> TextCleanupMode {
    return TextCleanupMode(rawValue: string) ?? .off
}
```

AppDelegate 中两处使用了不同的构造方式：

```swift
// 第 158 行
recordingController.textCleanupMode = TextCleanupMode.from(config.textCleanupMode)
// 第 234 行
self?.recordingController.textCleanupMode = TextCleanupMode(rawValue: modeString) ?? .off
```

两者等价但写法不一致。应统一使用 `from()` 或直接使用 `init(rawValue:) ?? .off`，不必同时存在。

### 3. temperature 硬编码在方法体内

**文件**: `Services/ServiceTextCleanup.swift` 第 127 行

```swift
"temperature": 0.3,
```

temperature 是影响输出质量的关键参数，应提升为类常量或 EngineeringOptions 配置项。对比 chatTranslate() 甚至没有设置 temperature（使用默认 1.0），两个 Chat Completions 调用在参数一致性上存在差异。

### 4. displayName 的国际化 key 与枚举 case 不对应

**文件**: `Services/ServiceTextCleanup.swift` 第 37 行

```swift
case .neutral: return lm.localized("Natural")
```

枚举 case 名是 `neutral`，但显示名用了 `"Natural"` 作为国际化 key。这不是 bug（国际化 key 可以不同于 case 名），但 `neutral` 和 `Natural` 的语义差异可能让维护者困惑——用户看到的是"自然"，内部标识是"中性"。

### 5. 注释质量：文件头注释完整且有价值

ServiceTextCleanup.swift 的文件头注释（第 1-23 行）非常好：描述了职责、三种模式、安全保障、依赖关系和架构角色。这是项目内一致性良好的地方。

---

## 错误处理

### 1. 错误回退策略不一致：URL 无效时返回 success，网络错误时返回 failure

**文件**: `Services/ServiceTextCleanup.swift`

```swift
// 第 108-110 行：URL 无效 -> 返回原始文本（success）
guard let url = URL(string: EngineeringOptions.chatCompletionsURL) else {
    completion(.success(text))  // 失败时返回原始文本
    return
}

// 第 148-151 行：网络错误 -> 返回 failure
if let error = error {
    completion(.failure(error))
    return
}
```

同类错误（"无法完成文本优化"）使用了不同的错误路径：
- URL 无效、JSON 序列化失败 → `completion(.success(text))`，调用方无感知
- 网络错误、HTTP 错误、解析失败 → `completion(.failure(error))`，由调用方处理回退

**调用方处理**（RecordingController 第 631-653 行）：对 failure 分支也是回退到原始文本，所以最终行为相同。但语义不一致：URL 无效是配置错误（永远不会自愈），静默回退掩盖了问题。

**建议**: 统一为所有错误都返回 failure，由调用方统一处理回退。或者统一为所有错误都返回 success(原始文本)。当前的混合策略增加了理解成本。

### 2. 缺少 API 限流（429）的特殊处理

**文件**: `Services/ServiceTextCleanup.swift` 第 167-171 行

```swift
if httpResponse.statusCode != 200 {
    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
    completion(.failure(CleanupError.apiError(httpResponse.statusCode, errorMessage)))
    return
}
```

所有非 200 状态码统一处理。对于 429 (Rate Limit) 错误，可以考虑短暂延迟后重试一次，因为文本优化是非关键路径，重试的成本低于丢失优化结果。

### 3. 空文本输入未做前置校验

**文件**: `Services/ServiceTextCleanup.swift` 第 102 行

cleanup() 方法没有检查 `text.isEmpty`。虽然空文本发到 API 不会报错（只会浪费一次 API 调用），但调用方 RecordingController 在 `handleResult()` 和 `localTranscribeWithTimeout()` 中已经过滤了空文本，所以实际不会发生。仍建议添加前置校验作为防御性编程。

### 4. 错误类型 LocalizedError 实现中使用了 `String(localized:)` 而非 `LocaleManager`

**文件**: `Services/ServiceTextCleanup.swift` 第 199-217 行

```swift
var errorDescription: String? {
    switch self {
    case .invalidResponse:
        return String(localized: "Text cleanup: invalid response")
```

CleanupError 的 errorDescription 使用了 `String(localized:)`（系统标准国际化），而其他日志消息使用 `LocaleManager.shared.logLocalized()`。这两套国际化机制并存，且 CleanupError.errorDescription 的字符串未出现在 LogStrings.xcstrings 中，可能不会被正确翻译。

不过这些 errorDescription 主要被 `error.localizedDescription` 调用，出现在 RecordingController 的日志中。如果项目的日志系统只依赖 LogStrings.xcstrings，这些错误描述将始终显示英文。

---

## Prompt 质量

### 1. sharedPreamble：功能正确但可优化

**文件**: `Services/ServiceTextCleanup.swift` 第 61-67 行

```swift
private static let sharedPreamble = """
    You are a text cleanup assistant. Your ONLY job is to clean up speech-to-text output. \
    CRITICAL RULES: \
    1) Do NOT translate - preserve the original language(s) exactly. If the input is Chinese, output Chinese. If mixed Chinese+English, keep both. \
    2) Do NOT add new information or change meaning. \
    3) Output ONLY the cleaned text, no explanations.
    """
```

**优点**:
- 明确了"不翻译"的核心约束，用 CRITICAL RULES 强调
- 对混合语言场景有明确指导
- "no explanations" 避免模型输出解释性文字

**改进空间**:
- 缺少对输入格式的说明：用户输入是语音转录文本（speech-to-text output），可以强调"输入可能包含 ASR 典型错误（同音字、断句错误、重复词）"
- 缺少对输出长度的约束：模型可能将短句扩展为长句（特别是 formal 模式），可以添加"保持与原文相近的长度"
- 三条规则中缺少"保持专有名词不变"的指导

### 2. neutral 模式 Prompt：最完善

```swift
.neutral: """
    Remove filler words (um, uh, like, you know, 那个, 就是, 然后呢, 嗯, 啊). \
    Fix grammar and punctuation. \
    Resolve self-corrections (keep only the correction). \
    Keep the tone unchanged.
    """,
```

**优点**: 列举了中英文常见填充词，明确了自我修正的处理方式（只保留修正后的版本）。

**改进空间**:
- 填充词列表不够全面：缺少"嗯..."、"啊..."、"对对对"、"basically"、"I mean"、"right"、"actually" 等
- 可以添加"修正 ASR 同音字错误"的指令（如"在场" vs "在长"）
- 中文标点符号处理未提及（如语音转录常缺少逗号、句号）

### 3. formal 模式 Prompt：过于简短

```swift
.formal: """
    Rewrite in formal, professional tone suitable for business emails. \
    Use complete sentences. \
    Avoid colloquialisms and contractions.
    """,
```

**问题**:
- "suitable for business emails" 限制了使用场景，用户可能在写报告、文档、学术论文
- 缺少对段落结构的指导（是否需要分段、添加标点）
- 缺少对中文正式语体的指导（仅 "formal" 对英文有明确含义，中文"正式"需要更具体的描述）
- 没有 neutral 模式中的"去填充词"指令，意味着 formal 模式可能保留填充词

### 4. casual 模式 Prompt：可能导致信息丢失

```swift
.casual: """
    Keep it casual and conversational. \
    Use common abbreviations where natural (NP, BTW, ASAP, etc.). \
    Keep it concise and friendly.
    """,
```

**问题**:
- "Keep it concise" 可能导致模型删减内容
- 缩写建议（NP, BTW, ASAP）是英文导向的，对中文输入不适用
- 同样缺少"去填充词"指令
- "casual" 的中文含义不够明确，可以添加"使用口语化表达，如'挺好的'替代'非常好'"

### 5. 通用 Prompt 问题

- **Prompt 结构**: sharedPreamble 和 modeInstructions 通过字符串拼接（第 114-115 行），中间只有 `\n`，格式上可能导致指令粘连。建议用 `\n\n` 分隔。
- **缺少 few-shot 示例**: 对于文本润色任务，添加一两个 input→output 示例能显著提高质量和一致性。
- **缺少输入语言检测指令**: 当输入是纯中文时，模型可能将英文缩写（如 ASAP）插入到中文文本中。

---

## 架构设计

### 1. 与 ServiceCloudOpenAI.chatTranslate() 的代码重复

ServiceTextCleanup.cleanup() 和 ServiceCloudOpenAI.chatTranslate() 几乎是同一个方法的复制粘贴：

| 代码段 | ServiceTextCleanup | ServiceCloudOpenAI |
|--------|--------------------|--------------------|
| URL 构建 | `EngineeringOptions.chatCompletionsURL` | 相同 |
| Auth header | `Bearer \(apiKey)` | 相同 |
| JSON payload 结构 | `model, messages, temperature` | `model, messages`（缺 temperature） |
| URLSession | `URLSession.shared.dataTask` | 相同 |
| 响应解析 | `choices[0].message.content` | 完全相同 |
| 行数 | 约 90 行 | 约 70 行 |

**建议**: 抽取一个通用的 `ChatCompletionsClient` 或在某个工具类中封装 Chat Completions API 调用，两个 Service 共用。这不仅减少重复，还确保超时策略、temperature、日志记录等保持一致。

### 2. ServiceTextCleanup 与 RecordingController 的交互方式：合理

```
RecordingController.outputText()
    ├── textCleanupMode == .off || translate → 直接输出
    └── textCleanupMode != .off → textCleanupService.cleanup()
                                      ├── success → 输出优化文本
                                      └── failure → 回退到原始文本
```

这个设计干净清晰：
- cleanup 是可选的后处理步骤，failure 安全回退
- 翻译模式跳过 cleanup（翻译结果已经是处理过的文本）
- 空结果检查（cleanedText.isEmpty 时使用原始文本）

### 3. ServiceTextCleanup 无状态设计：优秀

ServiceTextCleanup 只持有 `apiKey`，无其他状态。每次 cleanup() 调用都是独立的，没有隐式状态依赖。这使得它易于测试和替换。

### 4. apiKey 更新机制的间接性

当用户更新 API Key 时（AppDelegate 第 293-304 行），需要重新创建 ServiceTextCleanup 实例并通过 `updateServices()` 注入 RecordingController。这比直接暴露 setter 更安全（确保 key 更新的原子性），但代价是每次 key 变更都要重建三个 Service 实例。

这个设计与项目其他 Service（whisperService、realtimeService）保持一致，是可接受的。

---

## 性能

### 1. 文本优化增加的端到端延迟

文本优化是串行的后处理步骤，位于转录完成之后、文本输出之前。延迟 = 转录延迟 + 网络往返 + GPT 推理时间。

对于 gpt-4o-mini + 短文本（< 200 字），典型延迟约 0.5-1.5 秒。用户从停止录音到看到文本输出，总等待约 2-4 秒（转录 1-2 秒 + 优化 0.5-1.5 秒）。

**优化空间**:
- 可考虑使用 streaming 模式（`stream: true`）调用 Chat Completions API，边生成边通过 textInputter 输出，降低感知延迟
- 对极短文本（< 10 字）可跳过 cleanup，因为优化价值极低但延迟相对显著

### 2. Realtime 模式下的延迟放大

开启文本优化后，Realtime 模式的每个 segment 完成时都触发一次 cleanup API 调用（RecordingController 第 132-134 行）。如果用户说了 5 个 segment，就是 5 次串行 API 调用。

**问题**: 这些 cleanup 调用之间没有批处理或合并机制。如果 segment 间隔很短（例如 VAD 分句较频繁），可能产生大量并发 API 调用。

**优化建议**:
- 考虑在 Realtime 模式下攒批：等所有 segment 完成后，将完整文本一次性 cleanup
- 或者使用 debounce：最后一个 segment 完成后等待 500ms，合并所有待处理文本

### 3. 超时计算使用 audioDuration，但对文本优化无意义

**文件**: `Services/ServiceTextCleanup.swift` 第 121-122 行

```swift
let minutes = audioDuration / 60.0
let timeout = min(max(minutes * 10, EngineeringOptions.apiProcessingTimeoutMin), EngineeringOptions.apiProcessingTimeoutMax)
```

文本优化的处理时间取决于**文本长度**，而非**音频时长**。虽然两者正相关（长音频产生长文本），但 audioDuration 是一个间接代理。更准确的做法是基于 `text.count` 计算超时，但实际影响不大，因为 apiProcessingTimeoutMin (5s) 对大多数文本优化请求已经足够。

---

## 可扩展性

### 1. 添加新的润色模式

**当前难度：低**。添加新模式只需：
1. 在 `TextCleanupMode` 枚举添加 case
2. 在 `modeInstructions` 字典添加对应 prompt
3. 在 `displayName` 添加国际化名称
4. 在 UI Picker 中添加选项

设计良好，枚举 + 字典模式使得扩展简单。

### 2. 接入其他 LLM（如 Claude、Gemini、本地 LLM）

**当前难度：高**。ServiceTextCleanup 直接构造 OpenAI Chat Completions API 的 HTTP 请求，与 OpenAI 紧耦合：
- URL 硬编码为 OpenAI endpoint
- 请求 payload 格式是 OpenAI 特定的
- 响应解析是 OpenAI 特定的 `choices[0].message.content`

**建议**: 如果有接入多 LLM 的需求，定义 protocol：

```swift
protocol TextCleanupProvider {
    func cleanup(text: String, systemPrompt: String, completion: @escaping (Result<String, Error>) -> Void)
}
```

当前规模不需要过度设计，但这是一个可预见的扩展点。

### 3. 添加规则引擎（填充词删除、词语替换等）

**当前难度：中**。当前架构中没有规则引擎的位置。如果要添加：
- 可以在 `outputText()` 中，在 cleanup API 调用之前/之后插入规则处理步骤
- 或者在 ServiceTextCleanup 内部添加 `preprocess()` / `postprocess()` 方法
- 规则引擎可以作为零延迟的本地处理步骤，与 API 调用互补

### 4. 自定义 Prompt

**当前难度：中**。Prompt 是 `private static let`，用户无法自定义。如果要支持：
- 在 SettingsStore 添加 `customCleanupPrompt` 字段
- 在 TextCleanupMode 添加 `.custom` case
- cleanup() 中当 mode == .custom 时使用用户 prompt

---

## 配置管理

### 1. 硬编码汇总

| 硬编码项 | 位置 | 当前值 | 建议 |
|----------|------|--------|------|
| 模型名 | ServiceTextCleanup.swift:126 | `"gpt-4o-mini"` | 移至 EngineeringOptions |
| temperature | ServiceTextCleanup.swift:127 | `0.3` | 移至 EngineeringOptions 或类常量 |
| Prompt 文本 | ServiceTextCleanup.swift:61-87 | 内联字符串 | 可接受，但考虑抽取为可配置项 |

### 2. Config.textCleanupMode 使用 String 而非枚举

**文件**: `Config/Config.swift` 第 42 行

```swift
let textCleanupMode: String
```

整个配置传递链使用字符串：UserSettings (String) → SettingsStore (String) → Config (String) → RecordingController 处手动转换为 TextCleanupMode 枚举。

理想情况下 Config 和 SettingsStore 应直接使用 TextCleanupMode 枚举，但这需要解决 UserDefaults 序列化和 SwiftUI Picker binding 的兼容性。当前的 String 方案虽然不优雅，但与项目中其他设置项（defaultApiMode、autoSendMode）保持了一致。

---

## 与项目其他 Service 的一致性

### 一致的部分
- 错误类型定义模式（嵌套 enum + LocalizedError）与 ServiceCloudOpenAI.WhisperError 一致
- 回调模式（`Result<String, Error>` completion handler）全项目统一
- API Key 构造函数注入方式一致
- 文件头注释风格一致（职责、依赖、架构角色）
- 日志使用 `LocaleManager.shared.logLocalized()` 一致

### 不一致的部分

| 方面 | ServiceTextCleanup | ServiceCloudOpenAI.sendRequest |
|------|--------------------|---------------------------------|
| URLSession | `URLSession.shared` | 自定义 `URLSessionConfiguration` |
| 超时设置 | `request.timeoutInterval` | `sessionConfig.timeoutIntervalForRequest` |
| Session 生命周期 | 未管理 | `session.finishTasksAndInvalidate()` |
| temperature | 显式设置 0.3 | chatTranslate() 未设置（默认 1.0） |
| 日志记录 | 每个错误分支都有 `Log.e` | chatTranslate() 无日志 |
| 成功日志 | 有（第 182 行） | chatTranslate() 无 |

ServiceTextCleanup 在日志记录方面比 chatTranslate() 做得更好，但在 URLSession 管理方面不如 sendRequest() 规范。

---

## 安全性

### 1. 用户文本二次发送到 OpenAI

用户的转录文本通过 cleanup API 二次发送到 OpenAI Chat Completions API。对于可能包含敏感信息的语音（如密码、个人信息、商业机密），用户可能不知道文本被二次处理。

**建议**: 在设置面板的文本优化选项旁添加简短说明："文本将通过 OpenAI API 处理"。

### 2. 日志中输出完整文本

**文件**: `Services/ServiceTextCleanup.swift` 第 182 行

```swift
Log.i(... + " \"\(text)\" -> \"\(cleanedText)\"")
```

日志中同时输出了原始文本和优化后文本。对于包含敏感信息的语音内容，这些日志可能泄露隐私。这与项目中其他地方的日志行为一致（RecordingController 也输出转录结果），但值得注意。

---

## 总结

文本优化功能整体设计清晰、实现简洁。核心架构（可选后处理步骤 + 失败安全回退）是正确的。代码质量在项目内属于中上水平，日志记录比 chatTranslate() 更完善。

主要问题集中在两个方面：(1) 硬编码（模型名、temperature）带来的维护风险，特别是 gpt-4o-mini 退役问题；(2) Prompt 质量有提升空间，尤其是 formal/casual 模式对中文场景的覆盖不足。

### 优先级排序

| 优先级 | 问题 | 类型 |
|--------|------|------|
| P0 | gpt-4o-mini 模型硬编码，即将退役 | 可靠性 |
| P1 | Prompt 缺少中文正式/口语语体指导 | 质量 |
| P1 | formal/casual 模式缺少"去填充词"指令 | 质量 |
| P1 | 错误回退策略不一致（部分返回 success，部分返回 failure） | 代码质量 |
| P1 | 与 chatTranslate() 大量代码重复（~90 行） | 代码质量 |
| P2 | temperature 硬编码在方法体内 | 配置管理 |
| P2 | URLSession 使用方式与 sendRequest() 不一致 | 一致性 |
| P2 | Realtime 模式开启 cleanup 时无用户反馈（沉默等待） | 体验 |
| P2 | Realtime 模式多 segment 产生多次串行 API 调用 | 性能 |
| P2 | TextCleanupMode 枚举放在 Services 层 | 架构 |
| P2 | CleanupError.errorDescription 使用 String(localized:) 而非 LogStrings | 国际化 |
| P3 | 缺少空文本前置校验 | 防御性编程 |
| P3 | TextCleanupMode.from() 与 init(rawValue:) 重复 | 代码质量 |
| P3 | 超时基于 audioDuration 而非 text.count | 准确性 |
| P3 | 缺少自定义 Prompt 扩展点 | 可扩展性 |
| P3 | 缺少单元测试 | 测试 |
