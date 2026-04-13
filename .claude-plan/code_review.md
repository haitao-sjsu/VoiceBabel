# WhisperUtil 代码审查报告

## 总体评价

项目架构清晰，模块划分合理。AppDelegate 作为组合根，通过回调和 Combine 连接各组件，职责分离做得不错。代码质量整体良好，以下是发现的问题和改进建议。

---

## 已执行的清理

### 删除的死代码
1. **Config.swift**: 移除 `playSound` 和 `showNotifications` 字段（通过 SettingsStore 直接消费，Config 中的是死代码）
2. **UserSettings.swift**: 移除 `showNotifications`（整个项目中无任何消费者）
3. **UserSettings.swift**: 移除所有过时的 `【产品化迁移】` 注释（迁移已完成）
4. **Constants.swift**: 移除 `smartModeWaitDuration`（与 UserSettings 重复，总是被 SettingsStore 覆盖）
5. **RecordingController.swift**: 移除未使用的 `onCloudRecovered` 回调属性及其调用
6. **RecordingController.swift**: 移除多余空行
7. **HotkeyManager.swift**: 移除空的 `init() {}`
8. **AppDelegate.swift**: 移除无效的 `whisperLanguage` Combine 订阅（只记日志，`_ = self` 抑制警告）
9. **Constants.swift**: 移除多余空行

---

## 架构改进建议

### 1. Config 是半成品抽象层 ⚠️

**问题**: Config.load() 只代理了约 50% 的 EngineeringOptions 字段。其余字段（enableSilenceDetection, enableAudioCompression, enableCloudFallback, realtimeDeltaMode, enableTraditionalToSimplified, enableTagFiltering）由组件直接访问 `EngineeringOptions.xxx`。

**影响**: Config 作为抽象层既不完整也不必要——它增加了理解成本但没有提供完整的封装。

**建议**: 二选一：
- (A) 让 Config 完整代理所有 EngineeringOptions 字段，成为唯一的配置入口
- (B) 去掉 Config，让组件直接访问 EngineeringOptions + SettingsStore（当前的事实状态）

### 2. ApiMode/AutoSendMode 枚举放在 UI 层 ⚠️

**问题**: `StatusBarController.ApiMode` 和 `StatusBarController.AutoSendMode` 是域级概念，但定义在 UI 控制器内。RecordingController 依赖 `StatusBarController.ApiMode` 进行核心路由逻辑，形成了反向依赖（核心逻辑 → UI 层）。

**建议**: 将这两个枚举移到独立文件（如 `Config/ApiMode.swift`）或 Config 目录下。

### 3. Config 快照 vs SettingsStore 实时 — 双路径问题

**问题**: 部分用户设置通过 Config.load() 传入（启动时的一次性快照），但运行时变更通过 SettingsStore.$publisher 实时更新。这意味着 Config 中的用户设置字段在启动后就过时了。

**影响**: Config 的用户设置字段（whisperLanguage, defaultApiMode, autoSendMode 等）只在组件初始化时使用一次，之后 SettingsStore 的 Combine 订阅会覆盖它们。

**建议**: Config 只保留工程选项（EngineeringOptions 的代理），用户设置完全由 SettingsStore 管理。

### 4. Services 层的重复模式

**问题**:
- `ServiceCloudOpenAI.chatTranslate()` 和 `ServiceTextCleanup.cleanup()` 使用相同的 Chat Completions API 调用模式
- 超时计算公式 `min(max(分钟数×10, min), max)` 在两个服务中重复
- 各服务的错误枚举（WhisperError, CleanupError, RealtimeError）结构高度相似

**建议**:
- 提取共享的 `ChatCompletionsClient` 工具方法
- 超时计算提取为 Constants 的静态方法
- 考虑统一的 ServiceError 基础枚举（但优先级较低，当前分开也可接受）

### 5. 异步模式不一致

**问题**: ServiceLocalWhisper 使用现代 async/await，而 ServiceCloudOpenAI 和 ServiceTextCleanup 使用回调闭包。

**建议**: 长期来看可以将 HTTP 服务也迁移到 async/await，但当前不影响功能，优先级低。

---

### 6. 线程安全问题（Audio Agent 发现）

**AudioRecorder.audioBuffer 数据竞争**:
`audioBuffer` 在音频采集线程（installTap 回调）上写入，在主线程上读取（getAudioSamples, stopRecording）。没有同步机制。

**建议**: 用专用 DispatchQueue 保护 audioBuffer 的读写。

**Logger.fileHandle 无线程保护**:
`Log.i/w/e/d()` 可在任意线程调用，但 FileHandle 不是线程安全的。

**建议**: 用串行 DispatchQueue 保护文件 I/O。

### 7. AudioRecorder 性能优化（Audio Agent 发现）

- `processAudioBuffer` 中每次回调都创建新的 AVAudioConverter，可以在 startRecording 时创建一次复用
- `convertToPCM16` 的 Data() 未预分配容量，应使用 `Data(capacity: samples.count * 2)`

### 8. TextInputter 配置断连（Utilities Agent 发现）

`EngineeringOptions.inputMethod` 和 `typingDelay` 存在于配置中但从未连接到 TextInputter 的实例属性。TextInputter 总是使用硬编码默认值 `.clipboard` 和 `0`。

---

## 各模块设计评价

| 模块 | 评分 | 说明 |
|------|------|------|
| **AppDelegate** | ★★★★☆ | 组合根模式清晰，Combine 订阅合理。whisperLanguage 订阅已清理。 |
| **RecordingController** | ★★★★☆ | 状态机设计完善，API 路由逻辑清晰。文件较大(~760行)但职责统一。 |
| **HotkeyManager** | ★★★★★ | 状态机简洁优雅，冲突避免逻辑完善。 |
| **Config/** | ★★★☆☆ | 四个配置文件角色有重叠，见上方建议 1/3。 |
| **SettingsStore** | ★★★★★ | @Published + didSet 模式简洁有效。 |
| **Services/** | ★★★★☆ | 各服务职责清晰，错误处理健壮。有些重复代码可提取。 |
| **Audio/** | ★★★★★ | AudioRecorder 双模式设计精巧，AudioEncoder 回退策略稳健。 |
| **UI/** | ★★★★☆ | StatusBarController 包含域枚举是唯一问题。SettingsView 简洁。 |
| **Utilities/** | ★★★★★ | TextInputter 两种输入方式设计完善，Logger 和 NetworkHealthMonitor 简洁实用。 |
