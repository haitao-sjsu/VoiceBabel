# Code Review #08: 编码原则 2 & 3 审查

日期：2026-04-16

范围：审查所有非测试 Swift 源文件，对照 Principle 2（防御性编程，但不偏执）和 Principle 3（好的工艺，不过度工程化）。

---

## Principle 2 违规（防御性编程，但不偏执）

### P2-1: `AudioRecorder.processAudioBuffer()` 中的静默返回 —— 音频数据无声丢失

**文件：** `Audio/AudioRecorder.swift`，第 295、305、325 行

三个 `guard` 语句在失败时静默返回，没有任何日志：
- `AVAudioConverter` 创建失败（第 295 行）
- `AVAudioPCMBuffer` 分配失败（第 305 行）
- `floatChannelData` 提取失败（第 325 行）

此方法在音频采集线程上运行。如果任何一个 guard 失败，音频数据会被静默丢弃——用户在录音但缓冲区里什么都没有。没有日志的话，这个问题完全不可见。

**严重性：** 高——没有日志，生产环境无法调试。
**修复：** 在每个 early return 前添加 `Log.e()`。*（已在本次变更中修复）*

### P2-2: `@unknown default: break` 静默放行录音

**文件：** `Audio/AudioRecorder.swift`，第 168-169 行

```swift
case .denied, .restricted:
    throw RecordingError.permissionDenied
@unknown default:
    break  // 直接放行，开始录音
```

如果 Apple 在未来 macOS 版本中新增 `AVAuthorizationStatus` case，这里会静默允许录音继续。在框架边界上，防御性做法应该是默认拒绝。

**严重性：** 低（只在未来 OS 变更时触发），但修复成本极低。
**建议修复：** 添加 `Log.w()` 使未知 case 可见；或者直接 throw `RecordingError.permissionDenied`。

### P2-3: `Log` 工具类缺乏线程安全

**文件：** `Utilities/Log.swift`

`Log.log()` 被多个线程调用（音频采集线程、URLSession 回调、主线程），但 `fileHandle`、`lineCount` 和 `DateFormatter` 的访问没有同步保护。`DateFormatter` 本身不是线程安全的。并发调用可能导致日志文件损坏或崩溃。

**严重性：** 中——窗口期窄但风险真实存在。
**建议修复：** 为文件写入添加串行 `DispatchQueue`，或用 `os_unfair_lock` 保护共享状态。

### P2-4: `TextPostProcessor.convertChineseScript` 跨 Actor 访问 `@MainActor` 单例

**文件：** `Utilities/TextPostProcessor.swift`，第 45-46 行

`SettingsStore.shared` 标记了 `@MainActor`，但 `TextPostProcessor` 是一个没有 Actor 标注的静态工具类。如果 `convertChineseScript` 在非主线程被调用，会产生数据竞争。目前所有调用点恰好都在 MainActor 上，所以这是一个潜在问题。

**严重性：** 低（潜在，非活跃问题）。
**建议修复：** 给 `TextPostProcessor` 添加 `@MainActor`，或者把设置值作为参数传入。

---

## Principle 3 违规（好的工艺，不过度工程化）

### P3-1: 死代码——`TextInputter` 中的键盘输入路径 + 未连接的配置开关

**文件：** `Utilities/TextInputter.swift`，第 47-51 行；`Config/EngineeringOptions.swift`，第 139-143 行

`TextInputter` 有一个可配置的 `method` 属性（`.keyboard` / `.clipboard`）和 `typingDelay`，但代码库中没有任何地方设置它们——永远使用默认值。整个键盘输入路径（`typeText`、`typeCharacter`）实际上是死代码。

与此同时，`EngineeringOptions.inputMethod` 和 `EngineeringOptions.typingDelay` 存在但从未被连接到 `TextInputter`。

**严重性：** 中——死代码会招来复制粘贴式的错误复用。
**建议修复：** 要么在 `AppDelegate.setupComponents()` 中把 `EngineeringOptions` 的值连接到 `TextInputter`，要么如果键盘输入不在计划中就直接删除。

### P3-2: `LocalWhisperService` 和 `TextPostProcessor` 重复的标签过滤逻辑

**文件：** `Services/LocalWhisperService.swift` 第 169-171 行，`Utilities/TextPostProcessor.swift` 第 29-31 行

两处都用同一个 `\\[.*?\\]` 正则过滤 `[MUSIC]`、`[BLANK_AUDIO]` 等标签。由于 `RecordingController.outputText()` 总是对结果调用 `TextPostProcessor.process()`，本地转录结果会被过滤两次（幂等操作，不是 bug，但属于不必要的重复）。

**严重性：** 低——无功能影响，但违反单一职责。
**建议修复：** 从 `LocalWhisperService.transcribe()` 中移除标签过滤，让 `TextPostProcessor` 统一处理。

### P3-3: 领域枚举（`ApiMode`、`AutoSendMode`）错放在 UI 层

**文件：** `UI/StatusBarController.swift`，第 37-60 行

`StatusBarController.ApiMode` 被 `RecordingController`、`AppDelegate` 和 `NetworkHealthMonitor` 引用——这是一个领域概念，不是 UI 概念。同样，`AutoSendMode` 被 `AutoSendManager` 和 `AppDelegate` 使用。将领域类型嵌套在 UI 控制器里会造成不必要的耦合。

**严重性：** 低——功能上没问题，但代码组织可以更好。
**建议修复：** 将 `ApiMode` 和 `AutoSendMode` 移到共享位置（如顶层枚举或放入 `RecordingController`）。

### P3-4: `CloudOpenAIService.calculateProcessingTimeout` 不必要地暴露为公开方法

**文件：** `Services/CloudOpenAIService.swift`，第 184 行

`calculateProcessingTimeout` 拥有 internal（默认）访问级别，但只被 `sendRequest` 内部调用，没有外部调用者。

**严重性：** 极低。
**建议修复：** 改为 `private`。

---

## 汇总

| ID | 原则 | 文件 | 严重性 | 状态 |
|----|------|------|--------|------|
| P2-1 | 防御性 | AudioRecorder.processAudioBuffer | 高 | 已修复（已添加日志） |
| P2-2 | 防御性 | AudioRecorder auth @unknown default | 低 | 记录 |
| P2-3 | 防御性 | Log 线程安全 | 中 | 记录 |
| P2-4 | 防御性 | TextPostProcessor MainActor | 低 | 记录 |
| P3-1 | 工艺 | TextInputter 死代码 | 中 | 记录 |
| P3-2 | 工艺 | 重复标签过滤 | 低 | 记录 |
| P3-3 | 工艺 | ApiMode/AutoSendMode 放置位置 | 低 | 记录 |
| P3-4 | 工艺 | calculateProcessingTimeout 访问级别 | 极低 | 记录 |
