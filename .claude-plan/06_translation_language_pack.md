# Apple Translation 语言包管理实施计划

## Part 1：Apple Translation 语言包机制调研

### 1.1 核心 API

**LanguageAvailability**：检查语言对的可用状态。

```swift
let availability = LanguageAvailability()
let status = await availability.status(from: sourceLang, to: targetLang)
// 返回三种状态：
// .installed  — 已安装，可立即翻译
// .supported  — 支持但需下载语言包
// .unsupported — 不支持此语言对
```

**TranslationSession.prepareTranslation()**：提前触发语言包下载，不执行翻译。

```swift
// 在 .translationTask 闭包中调用
session.prepareTranslation()
```

用途：提前下载用户可能需要的语言包（例如用户即将离线时），避免翻译时才触发下载。

### 1.2 语言对方向性

语言包下载是**按语言对方向**检查的。`status(from: A, to: B)` 和 `status(from: B, to: A)` 可能返回不同结果。但实际上 Apple 的底层模型下载粒度不明确（Apple 未公开）——可能下载一个语言对后双向都可用，也可能不是。安全起见，应对每个需要的方向分别调用 `status()` 检查。

### 1.3 下载触发机制

Apple Translation Framework 的下载触发有两种方式：

1. **翻译时自动触发**：调用 `session.translate()` 时，如果语言包未安装，系统会弹出下载确认对话框。用户同意后开始下载，下载完成后自动完成翻译。
2. **prepareTranslation() 预下载**：主动调用 `session.prepareTranslation()`，同样弹出系统对话框请求用户确认下载。

**关键限制：无法静默下载。** 两种方式都会弹出系统级 UI（下载确认对话框 + 进度条）。这是 Apple 的设计决策——用户必须明确同意下载。无法像 WhisperKit 那样完全在后台静默下载。

### 1.4 下载进度追踪

**无法获取细粒度下载进度。** Apple 框架自行管理下载 UI（系统弹窗中显示进度条），不向开发者暴露进度百分比。开发者只能通过 `LanguageAvailability.status()` 轮询检查状态是否从 `.supported` 变为 `.installed`。

如果用户在下载进度 UI 中点击取消，会抛出 `CocoaError.userCancelled`，但下载实际上会在后台继续。

### 1.5 下载大小

Apple 未公开各语言包的具体大小。根据社区反馈，单个语言对的模型文件大小在几十 MB 到百余 MB 之间（远小于 WhisperKit 的 626MB）。语言包下载后全系统共享，其他 app 也可使用。

### 1.6 与 WhisperKit 下载的关键差异

| 维度 | WhisperKit 模型 | Apple Translation 语言包 |
|------|----------------|------------------------|
| 下载方式 | 程序内静默下载 | 系统弹窗 + 用户确认 |
| 进度追踪 | 可通过回调获取 | 系统 UI 显示，开发者不可控 |
| 存储位置 | App 目录内 | 系统级共享 |
| 下载大小 | ~626MB（单一模型） | 几十~百 MB/语言对 |
| 是否需用户交互 | 否 | 是（系统对话框） |

---

## Part 2：WhisperKit 下载流程参考

### 2.1 现有流程总结

```
AppDelegate.applicationDidFinishLaunching()
  └─ Task { try await localWhisperService.loadModel() }
       ├─ isModelLoading = true
       ├─ WhisperKit(config) — 自动下载或从缓存加载
       ├─ 成功 → isModelLoaded = true, isModelLoading = false
       └─ 失败 → isModelLoading = false, 抛出错误

AppDelegate 处理：
  ├─ 启动时发通知："Loading speech recognition model, first use requires download..."
  ├─ 成功 → 通知："Model loaded, local recognition ready"
  └─ 失败 → 通知："Model loading failed: {error}"
```

### 2.2 状态管理模式

ServiceLocalWhisper 维护两个布尔状态：
- `isModelLoaded`：模型是否已加载完毕
- `isModelLoading`：模型是否正在加载/下载中

RecordingController 在转录前检查 `localWhisperService.isReady()`，如果未就绪则报错。

### 2.3 可复用的设计模式

1. **启动时预加载**：AppDelegate 启动时异步触发加载，不阻塞 UI
2. **状态标志**：`isLoading` / `isLoaded` 双标志，UI 可据此显示不同提示
3. **通知机制**：通过 `statusBarController.showNotification()` 告知用户加载进度
4. **使用时检查**：实际使用前检查 `isReady()`，未就绪时给出友好提示

---

## Part 3：语言包管理架构设计

### 3.1 需要管理的语言对

基于用户设置，需要预下载的语言对：

**翻译目标语言**（`translationTargetLanguage`）决定了核心语言对。当 translationEngine 为 "apple" 或 "auto" 时才需要管理语言包。

需要覆盖的场景：
- 识别语言（`whisperLanguage`）→ 翻译目标语言（`translationTargetLanguage`）
- 如果识别语言为 "auto"（空字符串）或 "ui"，则无法预判源语言，应预下载常见语言对

实际需要预下载的语言对策略：
1. **明确语言对**：如果识别语言已指定（如 "zh"），则预下载 `zh → targetLang`
2. **自动检测模式**：如果识别语言为 auto，预下载 `常用语言 → targetLang`（如 zh→en, ja→en, ko→en 等，取决于 targetLang）
3. **简化方案（推荐）**：仅预下载用户设定的 `translationTargetLanguage` 相关的常用语言对，不做穷举

### 3.2 下载状态管理

由于 Apple 不提供细粒度进度，状态管理简化为三态：

```swift
enum TranslationPackStatus {
    case unknown       // 未检查
    case installed     // 已安装
    case notInstalled  // 需下载（supported 但未 installed）
    case unsupported   // 不支持
    case downloading   // 已触发下载（prepareTranslation 已调用）
}
```

在 ServiceAppleTranslation 中维护一个状态字典：

```swift
// key = "sourceCode→targetCode"，如 "zh→en"
private var packStatus: [String: TranslationPackStatus] = [:]
```

### 3.3 下载触发逻辑

#### 启动时

```
AppDelegate.applicationDidFinishLaunching()
  └─ 如果 translationEngine == "apple" 或 "auto"：
       └─ appleTranslationService.checkAndPrepareLanguagePacks()
            ├─ 根据当前 whisperLanguage + translationTargetLanguage 确定语言对
            ├─ 调用 LanguageAvailability.status() 检查
            ├─ 如果 .installed → 更新状态，结束
            ├─ 如果 .supported → 调用 prepareTranslation() 触发下载
            └─ 如果 .unsupported → 记录日志
```

#### 用户更改翻译目标语言时

```
SettingsStore.$translationTargetLanguage 变更
  └─ AppDelegate Combine 订阅
       └─ appleTranslationService.checkAndPrepareLanguagePacks()
            └─ 对新的语言对执行检查和下载
```

#### 用户更改识别语言时

```
SettingsStore.$whisperLanguage 变更
  └─ 现有 updateServicesLanguage() 之后
       └─ appleTranslationService.checkAndPrepareLanguagePacks()
```

### 3.4 状态通知机制

由于 Apple Translation 下载必须弹系统对话框，用户体验与 WhisperKit 有本质区别。通知策略：

1. **启动时检查结果**：
   - 已安装 → 静默，不通知
   - 需下载 → Log 记录 + 触发 prepareTranslation（系统弹窗即通知）
   - 不支持 → Log 警告

2. **翻译时未就绪**：
   - 如果 `packStatus` 为 `.notInstalled` 或 `.downloading`：
     - 仍然调用翻译（系统会自动弹下载对话框）
     - 同时通过 `statusBarController.showNotification()` 提示用户"正在下载语言包，请稍候"

3. **设置面板**：在 Translation Section 添加语言包状态指示器（可选，见 Part 4）

---

## Part 4：实施步骤

### Step 1：ServiceAppleTranslation 新增语言包管理方法

文件：`Services/ServiceAppleTranslation.swift`

新增方法：

```swift
/// 检查并预下载语言包
/// - Parameters:
///   - sourceLanguage: 源语言代码（nil 表示检查常用语言）
///   - targetLanguage: 目标语言代码
func checkAndPrepareLanguagePacks(
    sourceLanguage: String?,
    targetLanguage: String
) async -> TranslationPackStatus

/// 查询指定语言对的当前状态（不触发下载）
func languagePackStatus(
    source: String?,
    target: String
) async -> TranslationPackStatus

/// 触发 prepareTranslation（通过 SwiftUI 桥接）
/// 注意：此方法会弹出系统对话框
private func triggerPrepareTranslation(
    source: Locale.Language?,
    target: Locale.Language
)
```

新增属性：

```swift
/// 语言包状态缓存
private var packStatusCache: [String: TranslationPackStatus] = [:]

/// 语言包状态变更回调（通知 AppDelegate/UI）
var onPackStatusChanged: ((String, TranslationPackStatus) -> Void)?
```

`triggerPrepareTranslation` 实现方式：复用现有的 SwiftUI 桥接模式（隐藏 NSWindow + NSHostingController），创建一个新的 `PrepareTranslationHostView`，在 `.translationTask` 闭包中调用 `session.prepareTranslation()`。

```swift
private struct PrepareTranslationHostView: View {
    let configuration: TranslationSession.Configuration
    let completion: (Result<Void, Error>) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()
                    await MainActor.run { completion(.success(())) }
                } catch {
                    await MainActor.run { completion(.failure(error)) }
                }
            }
    }
}
```

### Step 2：AppDelegate 启动流程新增

文件：`AppDelegate.swift`

在 `applicationDidFinishLaunching()` 中，WhisperKit 模型预加载之后，新增翻译语言包检查：

```swift
// 现有：WhisperKit 模型预加载
Task { try await localWhisperService.loadModel() ... }

// 新增：Apple Translation 语言包检查
#if canImport(Translation)
if #available(macOS 15.0, *),
   let service = appleTranslationService as? ServiceAppleTranslation {
    let engine = EngineeringOptions.translationEngine
    if engine == "apple" || engine == "auto" {
        Task {
            let status = await service.checkAndPrepareLanguagePacks(
                sourceLanguage: settingsStore.whisperLanguage.isEmpty ? nil : settingsStore.whisperLanguage,
                targetLanguage: settingsStore.translationTargetLanguage
            )
            // 根据 status 记录日志
        }
    }
}
#endif
```

### Step 3：SettingsStore + Combine 订阅

文件：`AppDelegate.swift`（setupComponents 方法中）

新增 Combine 订阅：

```swift
// 翻译目标语言变更 → 检查语言包
settingsStore.$translationTargetLanguage.dropFirst()
    .receive(on: DispatchQueue.main)
    .sink { [weak self] targetLang in
        self?.checkTranslationLanguagePacks(targetLanguage: targetLang)
        Log.i(lm.logLocalized("Settings: Translation target language changed to") + " \(targetLang)")
    }.store(in: &cancellables)
```

新增辅助方法：

```swift
private func checkTranslationLanguagePacks(targetLanguage: String) {
    #if canImport(Translation)
    guard #available(macOS 15.0, *),
          let service = appleTranslationService as? ServiceAppleTranslation else { return }
    let engine = EngineeringOptions.translationEngine
    guard engine == "apple" || engine == "auto" else { return }
    Task {
        let sourceLang = settingsStore.whisperLanguage.isEmpty ? nil : settingsStore.whisperLanguage
        let status = await service.checkAndPrepareLanguagePacks(
            sourceLanguage: sourceLang,
            targetLanguage: targetLanguage
        )
        // 日志 + 通知
    }
    #endif
}
```

### Step 4：翻译时语言包未就绪的处理

文件：`RecordingController.swift`（translateTextViaApple 方法）

在调用 `service.translate()` 之前，检查语言包状态：

```swift
// 新增：检查语言包状态
let packStatus = await service.languagePackStatus(
    source: sourceLang.isEmpty ? nil : sourceLang,
    target: targetLanguage
)

if packStatus == .notInstalled {
    Log.i(lm.logLocalized("Translation language pack not installed, system will prompt for download"))
    // 不阻断翻译流程——translate() 调用时系统会自动弹下载对话框
    // 但给用户一个提示
}
```

这里的关键设计决策是：**不阻断翻译流程**。因为 `session.translate()` 在语言包未安装时会自动触发系统下载对话框，用户同意后下载完成会自动执行翻译。所以不需要在代码层面做额外的等待逻辑。

### Step 5：SettingsView 状态指示（可选）

文件：`UI/SettingsView.swift`

在 Translation Section 添加语言包状态指示，让用户了解当前语言对是否已下载：

```swift
Section("Translation") {
    Picker("Output Language", selection: $store.translationTargetLanguage) { ... }

    // 新增：语言包状态指示
    HStack {
        Text("Language Pack")
        Spacer()
        switch translationPackStatus {
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            Text("Ready").foregroundColor(.green).font(.caption)
        case .notInstalled:
            Image(systemName: "arrow.down.circle").foregroundColor(.orange)
            Text("Download Required").foregroundColor(.orange).font(.caption)
        case .downloading:
            ProgressView().scaleEffect(0.7)
            Text("Downloading...").foregroundColor(.secondary).font(.caption)
        case .unsupported:
            Image(systemName: "xmark.circle").foregroundColor(.red)
            Text("Not Supported").foregroundColor(.red).font(.caption)
        default:
            EmptyView()
        }
    }
}
```

为此需要在 SettingsStore 中新增一个 `@Published` 属性来传递语言包状态，或通过 ServiceAppleTranslation 的回调更新。

### Step 6：实现摘要

| 文件 | 改动 |
|------|------|
| `Services/ServiceAppleTranslation.swift` | 新增 `checkAndPrepareLanguagePacks()`、`languagePackStatus()`、`triggerPrepareTranslation()`、`PrepareTranslationHostView`、`packStatusCache`、`onPackStatusChanged` |
| `AppDelegate.swift` | 启动时调用语言包检查；新增 `$translationTargetLanguage` Combine 订阅；新增 `checkTranslationLanguagePacks()` 辅助方法 |
| `RecordingController.swift` | `translateTextViaApple()` 中新增语言包状态检查 + 日志提示（不阻断流程） |
| `Config/SettingsStore.swift` | （可选）新增 `@Published var translationPackStatus` 用于 UI 显示 |
| `UI/SettingsView.swift` | （可选）Translation Section 添加语言包状态指示行 |

---

## Part 5：风险和注意事项

### 5.1 系统对话框无法避免

这是最核心的约束。Apple Translation Framework **强制要求**用户通过系统对话框确认下载。这意味着：
- 无法像 WhisperKit 那样完全静默下载
- `prepareTranslation()` 调用后会弹出系统级 UI
- 如果在 AppDelegate 启动时调用，用户刚打开 app 就会看到下载弹窗

**缓解策略**：
- 启动时仅调用 `LanguageAvailability.status()` 检查状态（不弹窗）
- 仅在用户主动触发翻译、或在设置面板中主动操作时才调用 `prepareTranslation()`
- 或者：接受首次翻译时弹出下载对话框的体验（Apple 的预期用法）

### 5.2 SwiftUI 桥接的复杂性

`prepareTranslation()` 只能在 `.translationTask` modifier 的闭包中调用，这意味着必须复用现有的隐藏 NSWindow + NSHostingController 桥接模式。需注意：
- 每次调用需创建新的 SwiftUI View 并添加到隐藏窗口
- 需要超时保护（与现有 translate 方法一致）
- 需要防止重复调用（如果已经在下载中，不要再次触发）

### 5.3 状态同步的时机

`LanguageAvailability.status()` 返回的是调用时刻的快照。语言包可能在后台下载完成（用户在其他 app 或系统设置中下载了语言包），状态不会主动推送。

**缓解策略**：
- 每次翻译前都重新检查一次状态（`status()` 调用很轻量）
- 不过度缓存状态

### 5.4 语言代码映射

现有 `mapToLocaleLanguage()` 已处理 "zh" → "zh-Hans" 等映射。需要确保翻译目标语言列表中的所有语言代码都能正确映射。当前 SettingsView 中的翻译目标语言列表（en, zh, ja, ko, fr, de, es）应全部在 Apple Translation 支持范围内。

### 5.5 translationEngine 设置的影响

仅当 `EngineeringOptions.translationEngine` 为 "apple" 或 "auto" 时才需要管理语言包。如果设为 "cloud"，不需要做任何语言包相关操作。代码中应始终检查此开关。

### 5.6 用户体验取舍

由于无法静默下载，建议的用户体验流程：

**方案 A（推荐 — 懒下载）**：
1. 启动时静默检查语言包状态（只调用 `status()`，不弹窗）
2. 在设置面板 Translation Section 显示状态（已安装/需下载）
3. 用户首次翻译时，如果语言包未安装，系统自动弹出下载对话框
4. 下载完成后翻译自动完成

**方案 B（主动下载）**：
1. 启动时检查状态 + 调用 `prepareTranslation()`（会弹窗）
2. 用户更改语言时调用 `prepareTranslation()`（会弹窗）
3. 翻译时语言包已就绪，体验流畅

推荐方案 A，因为：
- 避免用户刚启动 app 就被弹窗干扰
- Apple 的翻译框架本身就设计为"翻译时自动触发下载"
- 与系统原生体验一致
- 在设置面板中给出状态提示即可（用户知道需要下载）

方案 B 的 `prepareTranslation()` 可以作为设置面板中的一个手动按钮（"预下载语言包"），让高级用户主动触发。

### 5.7 错误处理

- `prepareTranslation()` 可能抛出 `CocoaError.userCancelled`（用户关闭下载弹窗）—— 下载实际仍在后台继续，不应视为失败
- 网络不可用时下载会失败，需要 graceful 处理
- 翻译时如果语言包下载失败且 engine 为 "auto"，应回退到 Cloud GPT 翻译
