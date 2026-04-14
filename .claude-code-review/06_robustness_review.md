# WhisperUtil 健壮性分析报告

日期：2026-03-26

---

## 一、总体评估

WhisperUtil 整体架构清晰，组件间通过闭包回调松耦合连接，错误处理覆盖了大部分常见场景。特别值得肯定的是：
- 错误状态 3 秒自动恢复机制，防止应用卡死
- Cloud API 失败自动回退到本地 WhisperKit + 网络恢复自动切回
- M4A 编码失败自动回退 WAV
- 文本优化失败回退到原始文本

但在线程安全、资源管理、外部设备变化等方面存在若干风险，以下逐模块分析。

---

## 二、逐模块分析

### 2.1 Audio/AudioRecorder.swift

#### 当前优点
- 每次录音新建 AVAudioEngine 实例，避免残留状态
- 最长录音时间保护，防止意外长时间录音
- 麦克风冲突检测（Core Audio + 系统听写）

#### 风险点

**P0 - AVAudioEngine 在音频设备变化时崩溃**

这是已知的 HDMI 显示器问题的根源。当前代码在 `startRecording()` 中获取 `inputNode.outputFormat(forBus: 0)` 和 `installTap`，但：
1. 没有监听音频设备变化通知（`AVAudioEngineConfigurationChange`）
2. 录音期间如果系统默认输入设备变更（插拔耳机、连接 HDMI 显示器、蓝牙设备断连），AVAudioEngine 会抛出异常或产生无效格式
3. `inputFormat` 可能返回 channel count = 0 或采样率为 0 的无效格式（aggregate device 场景），导致 `AVAudioConverter` 创建失败

```swift
// AudioRecorder.swift:200 - 没有验证 inputFormat 的有效性
let inputFormat = inputNode.outputFormat(forBus: 0)
```

**修复建议**：
1. 在 `startRecording()` 中验证 `inputFormat.channelCount > 0 && inputFormat.sampleRate > 0`，无效时抛出明确错误
2. 注册 `AVAudioEngineConfigurationChange` 通知，设备变化时优雅停止录音并通知用户
3. 在 `audioEngine.start()` 外层用 `do-catch` 已经做了（好），但应在 catch 中清理 tap

**P1 - processAudioBuffer 中每次创建 AVAudioConverter**

```swift
// AudioRecorder.swift:313 - 在音频回调线程中每次都创建新的 converter
guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
    return
}
```

这个方法在音频采集线程上高频调用（每 ~21ms 一次），每次都创建一个新的 `AVAudioConverter` 实例。虽然功能上正确，但：
- 存在内存分配压力（频繁 alloc/dealloc）
- `AVAudioConverter` 初始化可能失败时静默 return，丢失音频数据而不报错

**修复建议**：将 `AVAudioConverter` 作为实例变量，在 `startRecording()` 时创建一次，在 `stopRecording()` 时释放。如果 converter 创建失败，应 Log.e 并停止录音。

**P1 - audioBuffer 的线程安全问题**

```swift
// AudioRecorder.swift:350 - 在音频回调线程写入
audioBuffer.append(contentsOf: samples)

// AudioRecorder.swift:282-285 - 在主线程读取
func getLastRecordingAverageRMS() -> Float {
    guard !audioBuffer.isEmpty else { return 0 }
    let sumOfSquares = audioBuffer.reduce(0) { $0 + $1 * $1 }
```

`audioBuffer` 在音频回调线程上被 `append`，但 `getLastRecordingAverageRMS()` 和 `getAudioSamples()` 在主线程被调用（RecordingController 的 `stopLocalRecording` 和 `stopCloudRecording` 中）。Swift Array 不是线程安全的，并发读写可能导致崩溃。

关键路径分析：`stopCloudRecording()` 先调用 `getAudioSamples()` 和 `getLastRecordingAverageRMS()`，然后才调用 `stopAndValidateRecording()` 中的 `stopRecording()`。在 `stopRecording()` 内部先 `removeTap` 再操作 buffer。这意味着读取 buffer 时 tap 仍在运行，存在竞态。

**修复建议**：使用 `DispatchQueue` 或 `os_unfair_lock` 保护 `audioBuffer` 的读写。或者调整调用顺序：先 removeTap 停止写入，再读取 buffer。

**P2 - convertToPCM16 的效率问题**

```swift
// AudioRecorder.swift:367-376 - 逐样本创建 Data
private func convertToPCM16(_ samples: [Float]) -> Data {
    var data = Data()
    for sample in samples { ...
```

逐样本 append 到 Data 效率较低。

**修复建议**：预分配 `Data(capacity: samples.count * 2)` 减少重分配。

---

### 2.2 Audio/AudioEncoder.swift

#### 当前优点
- M4A 失败自动回退 WAV，保证编码不会完全失败
- 临时文件用 defer 清理，不会泄露
- WAV 手动构建不依赖系统编码器

#### 风险点

**P2 - encodeToM4A 的大音频内存峰值**

对于 10 分钟录音（16000 * 600 = 960 万样本，约 36MB Float32），需要同时持有原始 `[Float]` 数组和 `AVAudioPCMBuffer`，峰值内存约 72MB。考虑到 macOS 内存通常充裕，不是严重问题，但值得注意。

---

### 2.3 RecordingController.swift

#### 当前优点
- 状态机设计清晰，状态转换有 guard 保护
- 错误 3 秒自动恢复，防止卡死
- 网络回退逻辑完善

#### 风险点

**P0 - 取消 processing 时旧回调仍会执行**

```swift
// RecordingController.swift:236-238
case .processing:
    Log.i("用户取消处理")
    currentState = .idle
```

当用户按 ESC 取消 processing 时，状态变为 idle，但 API 回调仍会执行。

问题场景：
1. 用户按 ESC 取消 processing，状态变为 idle
2. 用户立即开始新录音，状态变为 recording
3. 之前的 API 回调返回，`handleResult` 在 main queue 执行
4. `outputText` 向错误的应用窗口输入文本，并将状态错误地设为 idle
5. 用户的新录音被打断

**修复建议**：引入一个递增的 "session ID" 或 "generation counter"。每次开始新录音时递增，API 回调检查 session ID 是否匹配，不匹配则丢弃结果。

**P1 - Realtime 模式停止后的结果丢失**

```swift
// RecordingController.swift:577-583
private func stopRealtimeRecording() {
    _ = audioRecorder.stopRecording()
    audioRecorder.onAudioChunk = nil
    realtimeService.disconnect()
    currentState = .idle
    handleAutoSend()
}
```

调用 `disconnect()` 会立即关闭 WebSocket，但服务器可能还有正在处理的转录结果尚未返回。最后一段话的 `onTranscriptionComplete` 可能永远不会触发。

**修复建议**：停止录音后，先调用 `commitAudio()`，等待最后一个 `onTranscriptionComplete` 回调（设超时），收到后再断开连接。

**P1 - Realtime 模式连接失败时无超时**

调用 `connect()` 后，如果 WebSocket 连接一直建不上（DNS 解析慢、网络不可达但系统未立即报错），没有超时机制。注意此时 `currentState` 尚未被设为 `recording`（状态变更在 `onConnectionStateChange` 的 `.configured` 分支中才执行）。

**修复建议**：在 `startRealtimeRecording()` 中设置一个连接超时（如 10 秒），超时后调用 `disconnect()` 并报错。

**P2 - Realtime 模式 textCleanupMode + 多段 complete 的交互**

当文本优化开启时，`onTranscriptionComplete` 中的 `outputText` 会将状态设为 idle 并调用 `handleAutoSend`。但一次 Realtime 录音会话可能产生多段 `onTranscriptionComplete`，导致多次 `handleAutoSend`（多次按 Enter）。

**修复建议**：Realtime 模式下不应在每段 complete 时都 handleAutoSend，应在 `stopRealtimeRecording` 统一处理。

---

### 2.4 Services/ServiceCloudOpenAI.swift

#### 当前优点
- 动态超时计算合理
- 错误分类清晰（网络错误 vs API 错误，决定是否回退）
- multipart/form-data 手动构建正确

#### 风险点

**P1 - 每次请求创建新 URLSession**

```swift
// ServiceCloudOpenAI.swift:237-238
let sessionConfig = URLSessionConfiguration.default
let session = URLSession(configuration: sessionConfig)
```

虽然回调中调用了 `session.finishTasksAndInvalidate()`，但每次请求创建新 session 有性能开销。长期运行可能有资源积累。

**修复建议**：创建一个类级别的 URLSession 实例。超时差异可以通过 `URLRequest.timeoutInterval` 控制（对于 request-level timeout 是有效的）。

**P1 - API Key 过期/无效的错误信息不够友好**

```swift
// ServiceCloudOpenAI.swift:309-311
if httpResponse.statusCode != 200 {
    let errorMessage = String(data: data, encoding: .utf8) ?? "未知错误"
    completion(.failure(WhisperError.apiError(httpResponse.statusCode, errorMessage)))
```

当 API key 过期（401）或额度用完（429）时，用户看到的是原始 JSON 错误消息。

**修复建议**：对常见状态码提供中文友好提示：
- 401：「API 密钥无效或已过期」
- 429：「API 调用频率过高或额度已用完」
- 413：「音频文件过大」

**P2 - chatTranslate 使用 URLSession.shared**

与 `sendRequest` 使用自定义 session 不一致，但功能上不影响。

---

### 2.5 Services/ServiceRealtimeOpenAI.swift

#### 当前优点
- WebSocket 生命周期管理清晰（状态机）
- 断开连接时清理完整（cancel + invalidate + reset）

#### 风险点

**P0 - connectionState 的线程安全**

```swift
private var connectionState: RealtimeConnectionState = .disconnected
```

`connectionState` 被多个线程并发访问：
- WebSocket delegate 回调在后台线程
- `sendAudioChunk` 在音频回调线程读取
- `connect()` / `disconnect()` 在主线程写入
- `receiveMessage` completion 在后台线程读写

没有任何同步机制。

**修复建议**：使用 `os_unfair_lock` 或将所有状态访问串行化到一个 `DispatchQueue`。

**P1 - accumulatedTranscription 断开时丢失**

`accumulatedTranscription` 在 delta 事件中累加，在 complete 事件中重置。如果用户在 complete 事件前断开连接（stopRealtimeRecording 直接 disconnect），累积的文本丢失。

**修复建议**：在 `disconnect()` 中检查 `accumulatedTranscription` 是否非空，非空则触发 `onTranscriptionComplete`。

**P1 - 无 WebSocket 心跳/保活**

WebSocket 连接建立后没有心跳。长时间录音时（如讲座记录），中间网络设备（NAT、防火墙）可能因超时断开空闲连接。

**修复建议**：定期调用 `webSocket?.sendPing` 检测连接活性。

**P2 - connect() 失败时状态未重置**

```swift
// ServiceRealtimeOpenAI.swift:96-100
guard let url = URL(string: realtimeURL) else {
    let error = RealtimeError.invalidURL
    onError?(error)
    return  // connectionState 仍然是 .connecting，不会被重置
}
```

如果 URL 无效，`connectionState` 停留在 `.connecting`，后续 `connect()` 调用会因为 `guard connectionState == .disconnected` 而被拒绝。

**修复建议**：在错误路径中重置 `connectionState = .disconnected`。

---

### 2.6 Services/ServiceLocalWhisper.swift

#### 当前优点
- 温度回退策略提高识别率
- 幻觉检测（压缩比阈值）
- 模型加载状态追踪

#### 风险点

**P1 - loadModel 无重入保护**

如果 `loadModel()` 被并发调用两次（虽然当前代码路径只调用一次），没有 guard。

**修复建议**：添加 `guard !isModelLoading else { return }`。

**P1 - isModelLoaded/isModelLoading 的线程安全**

`loadModel()` 在 `Task` 中执行（可能在后台线程），设置 `isModelLoading` 和 `isModelLoaded`。`isReady()` 在主线程被调用。

**修复建议**：标记为 `@MainActor`，或使用 MainActor.run 包裹状态修改。

**P2 - WhisperKit transcribe 不响应 Task cancellation**

RecordingController 的超时机制用 `TaskGroup` 竞速，但如果 WhisperKit 的 `transcribe` 不检查 `Task.isCancelled`，超时后推理仍在后台消耗 CPU。

---

### 2.7 Services/ServiceTextCleanup.swift

#### 当前优点
- 所有失败路径都回退到原始文本，不丢失数据
- 超时基于音频时长动态计算

#### 风险点

**P2 - 无明显问题**

这是最健壮的模块之一，所有错误都有 fallback。

---

### 2.8 Utilities/TextInputter.swift

#### 当前优点
- 剪贴板模式保存并恢复原内容
- 支持 Unicode 字符（CJK）

#### 风险点

**P1 - 辅助功能权限未在关键路径上检查**

`checkAccessibilityPermission()` 存在但从未被调用。无权限时：
- 全局热键监听不工作
- CGEvent.post() 静默失败
- 用户完成录音转录后文本不会被输入，没有任何错误提示

**修复建议**：在 `applicationDidFinishLaunching` 中调用检查，无权限时提示用户。

**P1 - 剪贴板恢复可能覆盖用户操作**

```swift
// TextInputter.swift:156-161 - 0.1s 后恢复
DispatchQueue.main.asyncAfter(deadline: .now() + Constants.clipboardRestoreDelay) {
    pasteboard.clearContents()
    pasteboard.setString(original, forType: .string)
}
```

问题：
1. 如果用户在 0.1s 内复制了新内容，恢复会覆盖它
2. 只保存了 `.string` 类型，富文本/图片等内容会丢失
3. 0.1s 可能不够某些慢应用完成粘贴

**修复建议**：
1. 恢复前检查 `pasteboard.changeCount`，如果变了则不恢复
2. 适当增大延迟（如 0.3-0.5s）

**P2 - typeCharacter 只处理 BMP 字符**

```swift
// TextInputter.swift:209
var char = UniChar(String(character).utf16.first ?? 0)
```

`UniChar` 是 `UInt16`，只能表示 BMP（Basic Multilingual Plane）字符。Emoji 等 supplementary plane 字符（如 U+1F600）需要 surrogate pair，只取 `utf16.first` 会丢失一半。

**修复建议**：使用 `utf16` 的完整编码单元数组，传递给 `keyboardSetUnicodeString` 的 `stringLength` 应为实际 UTF-16 编码长度。

---

### 2.9 Utilities/NetworkHealthMonitor.swift

#### 当前优点
- NWPathMonitor + HTTP 探测双层机制
- 无网络时跳过探测，节省资源
- deinit 中清理

#### 风险点

**P2 - hasNetwork 跨线程读写**

在 global queue 上写入，在 main queue 的 Timer 中读取。Bool 赋值在实践中通常原子，但不是语言级保证。

---

### 2.10 HotkeyManager.swift

#### 当前优点
- 状态机设计清晰
- 冲突避免覆盖全面（组合键、其他修饰键）
- 全局 + 本地监听

#### 风险点

**P2 - 与辅助功能权限问题相关**

`NSEvent.addGlobalMonitorForEvents` 在无辅助功能权限时静默失败，热键只在应用菜单栏菜单打开时（本地监听）才工作。与 TextInputter 的 #11 相同根因。

---

### 2.11 AppDelegate.swift

#### 当前优点
- 组合根模式清晰
- Combine 订阅实时传播设置变更
- 优雅退出逻辑

#### 风险点

**P1 - whisperLanguage 变更不传播到 Service**

`ServiceCloudOpenAI`、`ServiceRealtimeOpenAI`、`ServiceLocalWhisper` 的 `language` 在 init 时固定。`SettingsStore.$whisperLanguage` 没有被订阅。用户在设置面板切换语言后，实际转录仍使用旧语言。

**修复建议**：添加 `whisperLanguage` 的 Combine 订阅，让 Service 的 language 属性可变。

**P1 - translationTargetLanguage 设置未被使用**

`SettingsView` 可以设置翻译目标语言，但 `chatTranslate` 中硬编码了 "Translate to English"：

```swift
// ServiceCloudOpenAI.swift:140
"content": "You are a translator. Translate the following text to English. ..."
```

用户选择翻译为中文/日文/韩文后，实际仍输出英文。

**修复建议**：将 `translationTargetLanguage` 传递给 ServiceCloudOpenAI，在 prompt 中使用动态语言。同时 `translate()` 方法（Whisper API 直接翻译）只支持英文输出，应当在用户选择非英文目标语言时自动切换到 two-step 方法。

**P1 - waitingToSend 状态下退出被延迟**

```swift
// AppDelegate.swift:97-107
if state == .idle || state == .error {
    return .terminateNow
}
pendingQuit = true
return .terminateLater
```

`waitingToSend` 不在立即退出的条件中，可能等待最多 15 秒才能退出。

**修复建议**：`waitingToSend` 也应视为可立即退出，退出时取消倒计时。

---

### 2.12 Config/ 模块

#### SettingsStore.swift

**P2 - 无明显问题**。`@MainActor` 保证线程安全，UserDefaults 类型不匹配有 fallback。

#### Config.swift

**P2 - 启动时快照设计的局限**

Config 是一次性快照，运行时变更依赖 Combine 订阅。但部分字段（如 `maxRecordingDuration`、`translationMethod`）来自 EngineeringOptions，本身就是编译期常量，所以快照设计合理。只有 `whisperLanguage` 等 UserSettings 字段需要运行时传播，这正是上面 #8/#9 的问题。

---

## 三、跨模块系统性风险

### P0 - 音频设备热插拔导致应用不可用

**场景描述**：
1. 用户连接 HDMI 显示器 / 蓝牙耳机 / USB 麦克风
2. macOS 创建 aggregate device 或切换默认输入设备
3. AVAudioEngine 的 inputNode format 变得无效（channelCount=0 或采样率=0）
4. 后续所有录音操作都会失败

**当前处理**：没有任何设备变化监听。

**完整修复方案**：
1. 在 AppDelegate 中注册 `NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, ...)`
2. 收到通知时，如果正在录音则优雅停止并通知用户「音频设备变更，录音已中断」
3. 在 `AudioRecorder.startRecording()` 中验证 `inputFormat.channelCount > 0 && inputFormat.sampleRate > 0`
4. 如果验证失败，枚举所有可用输入设备，尝试选择一个有效的设备
5. 提供用户友好的错误消息：「当前音频输入设备不可用，请检查麦克风连接」

### P1 - 辅助功能权限缺失导致功能静默失效

**影响范围**：HotkeyManager（全局热键）+ TextInputter（文本输入），两个核心功能同时失效。

**修复方案**：
1. 在 `applicationDidFinishLaunching` 中调用 `TextInputter.checkAccessibilityPermission()`
2. 如果未授权，显示通知/弹窗引导用户到系统设置
3. 可以定期检查（如每次录音开始时），因为用户可能在运行后才授权

### P1 - 长时间运行后的资源积累

**影响**：作为菜单栏常驻工具，可能运行数天。
- ServiceCloudOpenAI 每次请求创建新 URLSession
- 每次录音创建新 AVAudioEngine 实例（正常释放则无问题）

**修复方案**：ServiceCloudOpenAI 使用单例 URLSession。

---

## 四、按优先级汇总

### P0（必须修复 - 可能导致崩溃或功能完全失效）

| # | 模块 | 问题 | 影响 |
|---|------|------|------|
| 1 | AudioRecorder | AVAudioEngine 无设备变化监听/格式验证 | HDMI/蓝牙等设备变化后录音完全失效 |
| 2 | ServiceRealtimeOpenAI | connectionState 无线程安全保护 | 并发读写可能导致崩溃 |
| 3 | RecordingController | 取消 processing 后旧回调仍执行 | 文本输入到错误窗口，状态机被干扰 |

### P1（重要 - 功能异常或用户体验问题）

| # | 模块 | 问题 | 影响 |
|---|------|------|------|
| 4 | AudioRecorder | audioBuffer 跨线程读写无保护 | 潜在崩溃 |
| 5 | AudioRecorder | processAudioBuffer 每次创建 AVAudioConverter | 性能浪费 + 静默丢数据 |
| 6 | RecordingController | Realtime 停止时立即断开，丢失最后一段 | 最后一句话丢失 |
| 7 | RecordingController | Realtime 连接无超时 | 网络问题时无反馈 |
| 8 | AppDelegate | whisperLanguage 变更不传播到 Service | 切语言不生效 |
| 9 | AppDelegate | translationTargetLanguage 未被使用 | 设置面板选项无效 |
| 10 | AppDelegate | waitingToSend 状态下退出被延迟 | 退出体验差 |
| 11 | TextInputter | 辅助功能权限未检查 | 功能静默失效 |
| 12 | TextInputter | 剪贴板恢复可能覆盖用户操作 | 剪贴板内容丢失 |
| 13 | ServiceCloudOpenAI | 401/429 错误信息不友好 | 用户不知如何解决 |
| 14 | ServiceLocalWhisper | loadModel 无重入保护 + 线程安全 | 并发加载出错 |
| 15 | ServiceRealtimeOpenAI | 无心跳保活机制 | 长录音时连接可能断开 |
| 16 | ServiceRealtimeOpenAI | 断开时 accumulatedTranscription 丢失 | delta 文本丢失 |
| 17 | ServiceRealtimeOpenAI | connect() 失败时状态未重置 | 后续连接被拒绝 |
| 18 | ServiceCloudOpenAI | 每次请求创建新 URLSession | 资源泄露（长期运行） |

### P2（改进 - 代码质量和边缘场景）

| # | 模块 | 问题 |
|---|------|------|
| 19 | AudioRecorder | convertToPCM16 未预分配 Data 容量 |
| 20 | NetworkHealthMonitor | hasNetwork 跨线程读写 |
| 21 | RecordingController | Realtime textCleanup + 多段 complete 多次 autoSend |
| 22 | TextInputter | typeCharacter 只处理 BMP 字符，Emoji 不完整 |

---

## 五、建议优先实施顺序

1. **第一批**（核心可靠性）：#1 音频设备变化监听 + #3 取消 processing session ID + #11 辅助功能权限检查
2. **第二批**（数据正确性）：#2 connectionState 线程安全 + #4 audioBuffer 线程安全 + #8 语言变更传播 + #9 翻译目标语言实现
3. **第三批**（体验优化）：#6 Realtime 最后一段结果 + #7 Realtime 连接超时 + #13 友好错误信息 + #12 剪贴板恢复改进
4. **第四批**（代码质量）：#5 AVAudioConverter 复用 + #14 loadModel 保护 + #17 connect 状态重置 + #18 URLSession 单例化
