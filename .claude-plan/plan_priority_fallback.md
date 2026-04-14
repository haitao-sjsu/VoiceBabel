# 优先级队列模式：调研与实施计划

## Part A：调研发现

### A1. 现有模式选择与 Fallback 完整流程

#### 转录模式选择

当前转录模式选择是**单一模式 + 硬编码 fallback**的架构：

1. **用户选择**：用户在 Settings 面板中选择 `defaultApiMode`（`SettingsView.swift:118-122`），值为 `"local"` / `"cloud"` / `"realtime"` 字符串。

2. **传播链路**：
   - `SettingsStore.defaultApiMode`（`SettingsStore.swift:59`）通过 `@Published` 发布变更
   - `AppDelegate.swift:209-221` 订阅变更，调用 `recordingController.userDidChangeApiMode(mode)`
   - `RecordingController.swift:585-593` 同时更新 `preferredApiMode` 和 `currentApiMode`

3. **录音启动时的模式路由**（`RecordingController.swift:218-251`）：
   ```
   startRecording()
     ├── currentApiMode == .local && transcribe  → startLocalRecording()
     ├── currentApiMode == .realtime && transcribe → startRealtimeRecording()
     └── 其他（cloud 转录 / 所有翻译）          → startNonStreamingRecording()
   ```

4. **录音停止时的模式路由**（`RecordingController.swift:335-351`）：
   ```
   stopRecording()
     ├── .local && transcribe    → stopLocalRecording()
     ├── .cloud && transcribe    → stopCloudRecording()
     ├── .realtime && transcribe → stopRealtimeRecording()
     └── 翻译模式               → stopTranslationRecording()
   ```

#### 现有 Fallback 机制

Cloud → Local 的 fallback 是**硬编码**在 `stopCloudRecording()` 中的（`RecordingController.swift:382-407`）：

1. Cloud API 调用失败时，进入 `case .failure` 分支
2. 调用 `shouldFallbackToLocal(error:)`（`RecordingController.swift:409-422`）判断是否应 fallback：
   - 必须 `EngineeringOptions.enableCloudFallback == true`
   - 必须 `localWhisperService.isReady() == true`
   - 必须是 `WhisperError.networkError`（非 API 错误）
3. 满足条件时调用 `fallbackToLocalTranscription(samples:)`（`RecordingController.swift:424-442`）
4. Fallback 后设置 `isInFallbackMode = true`，`currentApiMode = .local`
5. `NetworkHealthMonitor` 周期性探测网络恢复（`AppDelegate.swift:148-154`），恢复后调用 `recoverFromFallback()`（`RecordingController.swift:595-601`）

**关键限制**：
- 只支持 Cloud → Local 单向 fallback，不支持其他方向
- Realtime 模式失败不会 fallback
- fallback 判断逻辑硬编码在 `stopCloudRecording()` 方法内部

#### 翻译模式选择

翻译方法由 `EngineeringOptions.translationMethod`（`EngineeringOptions.swift:162`）控制，当前硬编码为 `"two-step"`，不向用户暴露。

`translateAudio()` 方法（`RecordingController.swift:535-548`）根据 `config.translationMethod` 分发：
- `"two-step"` → `whisperService.translateTwoStep()`：先 gpt-4o-transcribe 转录，再 gpt-4o-mini 翻译
- 其他 → `whisperService.translate()`：whisper-1 直接翻译为英文

翻译功能**不支持 fallback**——失败直接报错。

#### 两个关键状态变量

- `preferredApiMode`：用户选择的偏好模式（`RecordingController.swift:63`）
- `currentApiMode`：实际使用的模式，fallback 时会与 preferred 不同（`RecordingController.swift:64`）

### A2. 现有架构中需要改动的关键点

| 改动点 | 文件 | 说明 |
|--------|------|------|
| 模式优先级存储 | `SettingsStore.swift` | 新增转录/翻译优先级数组 |
| 模式优先级默认值 | `UserSettings.swift` | 新增默认优先级序列 |
| Config 传递 | `Config.swift` | 新增优先级字段 |
| 调度逻辑重写 | `RecordingController.swift` | 用优先级队列替代硬编码 if-else 路由 |
| Fallback 逻辑重写 | `RecordingController.swift` | 用通用"下一优先级"替代硬编码 Cloud→Local |
| 翻译方法暴露 | `EngineeringOptions.swift` → `SettingsStore.swift` | `translationMethod` 从工程选项迁移为用户设置 |
| 设置面板 UI | `SettingsView.swift` | 新增拖拽排序 Section |
| Combine 订阅 | `AppDelegate.swift` | 新增优先级变更的订阅和传播 |

### A3. SwiftUI 拖拽排序技术方案

#### 方案选型：`List` + `ForEach` + `.onMove`

对于本项目（仅 2-3 个可排序项），最佳方案是 SwiftUI 原生的 `List` + `ForEach` + `.onMove(perform:)` 组合：

```swift
List {
    ForEach(transcriptionPriority, id: \.self) { mode in
        PriorityRow(mode: mode)
    }
    .onMove { from, to in
        transcriptionPriority.move(fromOffsets: from, toOffset: to)
    }
}
```

**优势**：
- SwiftUI 原生支持，无需第三方依赖
- macOS 上开箱即用的拖拽手柄（三横线图标）
- 代码量极小，维护成本低
- 与现有 `SettingsView` 的 `Form { ... }.formStyle(.grouped)` 风格统一

**macOS 注意事项**：
- macOS 上 `List` + `.onMove` 自动显示拖拽手柄（grip handle），无需额外处理
- 如需更精细的交互控制，可使用 `.moveDisabled(!isHovering)` + `.onHover()` 组合限制拖拽起始区域
- 项目数量很少（转录 3 项，翻译 2 项），不存在性能问题

**不采用的方案**：
- `draggable()` / `dropDestination()` (Transferable)：过于复杂，适合跨应用拖拽
- 第三方库（ReorderableForEach 等）：项目数量极少，引入外部依赖不值得
- 自定义 DragGesture：增加代码复杂度，无明显收益

---

## Part B：实施计划

### B1. 整体架构设计

#### 数据模型

定义两个有序数组，存储在 UserDefaults 中：

```swift
// 转录优先级（有序数组，索引 0 = 最高优先级）
// 默认值：["cloud", "local", "realtime"]
var transcriptionPriority: [String]

// 翻译优先级（有序数组）
// 默认值：["two-step", "one-step"]
var translationPriority: [String]
```

**存储方式**：UserDefaults 的 `[String]` 数组，与现有 `SettingsStore` 的 `String` 存储风格一致。无需 Codable，简单字符串数组足矣。

#### 调度逻辑

```
用户按下录音键
    → 读取优先级数组 transcriptionPriority
    → 从 index 0 开始尝试
    → 模式失败且可 fallback？ → index += 1，尝试下一个
    → 所有模式都失败 → 报错
```

对于翻译：
```
用户按下翻译键
    → 读取优先级数组 translationPriority
    → 从 index 0 开始尝试
    → 失败 → 尝试下一个
    → 所有方法都失败 → 报错
```

#### Fallback 判断规则

不同模式的 fallback 条件不同：
- **Cloud**：网络错误时可 fallback（保持现有 `shouldFallbackToLocal` 的逻辑，泛化为 `shouldFallback`）
- **Realtime**：WebSocket 连接失败或断开时可 fallback
- **Local**：模型未加载时可 fallback（跳过该模式尝试下一个）
- **翻译两步法**：任一步骤网络失败时可 fallback
- **翻译一步法**：网络失败时可 fallback

### B2. 后端改动清单

#### 新增类型

在 `RecordingController.swift` 中新增：

```swift
/// 转录模式标识（用于优先级数组）
enum TranscriptionBackend: String, CaseIterable {
    case cloud = "cloud"
    case realtime = "realtime"
    case local = "local"
}

/// 翻译方法标识（用于优先级数组）
enum TranslationMethod: String, CaseIterable {
    case twoStep = "two-step"
    case oneStep = "one-step"
}
```

#### 需要修改的文件和方法

**1. `Config/UserSettings.swift`** — 新增默认优先级
```swift
static let transcriptionPriority = ["cloud", "local", "realtime"]
static let translationPriority = ["two-step", "one-step"]
```

**2. `Config/SettingsStore.swift`** — 新增 Published 属性
```swift
@Published var transcriptionPriority: [String]
@Published var translationPriority: [String]
```
- `init()` 中从 UserDefaults 读取，fallback 到 `UserSettings` 默认值
- `didSet` 中写入 UserDefaults

**3. `Config/Config.swift`** — 新增字段
```swift
let transcriptionPriority: [String]
let translationPriority: [String]
```
- `Config.load()` 中从 `UserSettings` 读取
- 移除 `translationMethod` 字段（被 `translationPriority` 取代）

**4. `RecordingController.swift`** — 核心改动

(a) 新增属性：
```swift
var transcriptionPriority: [String] = UserSettings.transcriptionPriority
var translationPriority: [String] = UserSettings.translationPriority
```

(b) 替换 `preferredApiMode` / `currentApiMode` 的单模式逻辑。不再需要 `preferredApiMode`，改为使用 `transcriptionPriority[0]` 作为首选模式。`currentApiMode` 保留，用于标识当前实际使用的模式。

(c) 重写 `stopCloudRecording()`，将 fallback 逻辑泛化：
```swift
private func transcribeWithFallback(
    recording: AudioRecorder.RecordingResult,
    samples: [Float],
    audioDuration: TimeInterval,
    priorityIndex: Int = 0
) {
    let priority = transcriptionPriority
    guard priorityIndex < priority.count else {
        handleError("All transcription modes failed")
        return
    }
    let mode = priority[priorityIndex]
    // 尝试该模式，失败时递归调用 priorityIndex + 1
}
```

(d) 类似地重写 `translateAudio()`：
```swift
private func translateWithFallback(
    recording: AudioRecorder.RecordingResult,
    audioDuration: TimeInterval,
    priorityIndex: Int = 0
) { ... }
```

(e) 移除 `shouldFallbackToLocal()` 和 `fallbackToLocalTranscription()`——被通用 fallback 逻辑取代。

(f) 简化 `userDidChangeApiMode()` → 改为 `userDidChangePriority()`。

**5. `AppDelegate.swift`** — Combine 订阅

新增两个订阅：
```swift
settingsStore.$transcriptionPriority.dropFirst()...sink { [weak self] priority in
    self?.recordingController.transcriptionPriority = priority
    // 更新 currentApiMode 为 priority[0]
    // 更新 StatusBar 图标
}

settingsStore.$translationPriority.dropFirst()...sink { [weak self] priority in
    self?.recordingController.translationPriority = priority
}
```

**6. `Config/EngineeringOptions.swift`** — 移除 `translationMethod`

将 `translationMethod`（`EngineeringOptions.swift:162`）迁移为用户设置，从 `EngineeringOptions` 中移除。`enableCloudFallback` 保留——它控制的是"是否允许 fallback"这个工程级开关。

**7. 网络恢复逻辑调整**

`NetworkHealthMonitor` 和 `recoverFromFallback()` 需要适配新逻辑：
- 恢复时不再切换到 `preferredApiMode`，而是将 `currentApiMode` 恢复为 `transcriptionPriority[0]`
- `isInFallbackMode` 的含义不变：当前正在使用非首选模式

### B3. 前端 UI 设计

#### 设置面板新增 Section

在 `SettingsView.swift` 中，将现有的 "Transcription" Section 改造为包含优先级排序的版本：

```
┌─ Transcription ──────────────────────────┐
│                                          │
│  Transcription Priority                  │
│  ┌──────────────────────────────────┐    │
│  │ ≡  ☁️  Cloud API                │    │
│  │     gpt-4o-transcribe           │    │
│  ├──────────────────────────────────┤    │
│  │ ≡  🏠  Local (WhisperKit)       │    │
│  │     On-device, offline          │    │
│  ├──────────────────────────────────┤    │
│  │ ≡  📶  Realtime API             │    │
│  │     WebSocket streaming         │    │
│  └──────────────────────────────────┘    │
│                                          │
│  Text Cleanup  [ Off              ▾ ]    │
│                                          │
├─ Translation ────────────────────────────┤
│                                          │
│  Translation Priority                    │
│  ┌──────────────────────────────────┐    │
│  │ ≡  📝  Two-step                 │    │
│  │     Transcribe + GPT translate  │    │
│  ├──────────────────────────────────┤    │
│  │ ≡  ⚡  One-step                 │    │
│  │     Whisper direct translation  │    │
│  └──────────────────────────────────┘    │
│                                          │
│  Output Language  [ English       ▾ ]    │
│                                          │
└──────────────────────────────────────────┘
```

#### 每个模式项显示的信息

| 元素 | 说明 |
|------|------|
| 拖拽手柄 (≡) | macOS List 自动提供 |
| 图标 | 区分模式的 emoji |
| 名称 | 模式主标题（已 i18n） |
| 描述 | 灰色副标题，简述模式特点 |

#### 交互流程

1. 用户打开设置面板，看到转录和翻译的优先级列表
2. 拖拽某一行到新位置，松开即生效
3. 列表顺序实时保存到 UserDefaults
4. StatusBar 图标跟随首选模式（priority[0]）更新
5. 下一次录音时按新顺序尝试

#### UI 实现代码骨架

```swift
// SettingsView.swift 中新增
Section("Transcription") {
    Text("Transcription Priority")
        .font(.caption)
        .foregroundColor(.secondary)

    List {
        ForEach(store.transcriptionPriority, id: \.self) { mode in
            TranscriptionPriorityRow(mode: mode)
        }
        .onMove { from, to in
            store.transcriptionPriority.move(fromOffsets: from, toOffset: to)
        }
    }
    .frame(height: 120) // 3 行的固定高度

    Picker("Text Cleanup", selection: $store.textCleanupMode) { ... }
}
```

### B4. 分步实施计划

#### Phase 1：数据模型与存储（可独立验证）

**目标**：优先级数据能正确存储和读取

**改动文件**：
- `Config/UserSettings.swift` — 添加默认优先级值
- `Config/SettingsStore.swift` — 添加两个 `@Published` 数组属性
- `Config/Config.swift` — 添加优先级字段，移除 `translationMethod`

**验证方式**：
- Build 成功
- 在 `AppDelegate` 中打 log 确认优先级数组正确加载
- 手动修改 UserDefaults 验证持久化

#### Phase 2：后端调度逻辑重写（可独立验证）

**目标**：RecordingController 按优先级队列依次尝试，失败自动 fallback

**改动文件**：
- `RecordingController.swift` — 重写调度和 fallback 逻辑
- `AppDelegate.swift` — 新增 Combine 订阅

**验证方式**：
- 默认优先级 [Cloud, Local, Realtime]：正常使用 Cloud 转录
- 断网测试：Cloud 失败后自动 fallback 到 Local
- 修改优先级为 [Local, Cloud]：直接使用 Local 转录
- 翻译测试：两步法/一步法按优先级尝试

#### Phase 3：设置面板拖拽排序 UI（可独立验证）

**目标**：用户可在设置面板中拖拽调整优先级

**改动文件**：
- `UI/SettingsView.swift` — 新增优先级排序 UI

**验证方式**：
- 拖拽排序操作流畅
- 排序结果实时保存（关闭设置面板后重开，顺序不变）
- StatusBar 图标跟随首选模式变化

#### Phase 4：i18n 与收尾

**目标**：所有新增 UI 文本完成国际化

**改动文件**：
- `WhisperUtil/Localizable.xcstrings` — 新增 key
- `WhisperUtil/LogStrings.xcstrings` — 新增 log key

**验证方式**：
- 切换界面语言，所有文本正确显示
- log 输出使用正确语言

### B5. 风险和注意事项

1. **Realtime 模式的 fallback 时机**：Realtime 模式通过 WebSocket 流式转录，没有明确的"一次转录失败"时点。需要定义何时判定 Realtime 失败——建议在连接失败（`connectionState` 从非 disconnected 变为 disconnected）时触发 fallback，而非在流式传输中途。

2. **录音数据兼容性**：
   - Cloud 模式使用编码后的音频数据（M4A/WAV）
   - Local 模式使用 Float32 PCM samples
   - Realtime 模式使用 PCM16 24kHz
   - fallback 时需要确保目标模式能使用已有的录音数据。当前的 `stopCloudRecording()` 已经通过 `audioRecorder.getAudioSamples()` 提前保存了 samples 用于 fallback，新方案需要保持这一设计。

3. **Realtime → 其他模式的 fallback 数据问题**：Realtime 模式在录音开始前就建立 WebSocket 连接，如果连接失败，此时还没有录音数据，无法 fallback。建议策略：Realtime 连接失败时提示用户重试，或者先录音再 fallback（但这需要改变 Realtime 的录音流程）。**最简方案**：Realtime fallback 仅在连接建立前触发，提示用户"Realtime 不可用，已切换到下一优先级模式"，下次录音自动使用下一模式。

4. **翻译一步法的局限**：一步法使用 `whisper-1` 模型，只能翻译成英文。如果用户设置了非英文的翻译目标语言（`translationTargetLanguage`），一步法应自动跳过或标记为不可用。

5. **`List` 嵌套在 `Form` 中的布局**：SwiftUI 的 `Form` + `.formStyle(.grouped)` 中嵌套 `List` 可能产生滚动冲突。需要测试实际效果，可能需要改用 `ForEach` + `.onMove` 直接放在 `Section` 内（不额外嵌套 `List`）。

6. **`EngineeringOptions.enableCloudFallback` 的语义变化**：原来控制"Cloud → Local 是否允许 fallback"，新方案中应泛化为"是否允许任何模式间的 fallback"。建议重命名为 `enableModeFallback`。

7. **向后兼容**：用户升级后，UserDefaults 中没有优先级数组。`SettingsStore.init()` 需要正确 fallback 到 `UserSettings` 默认值。如果用户之前选择了 `defaultApiMode = "local"`，升级后应将 local 放在优先级数组首位——需要迁移逻辑。
