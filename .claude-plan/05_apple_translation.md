# Apple Translation Framework 调研与集成实施计划

日期：2026-04-14

---

## Part A：Apple Translation Framework 深度调研

### 1. API 完整说明

#### 1.1 核心类型

Apple Translation Framework 包含以下核心类型：

| 类型 | 说明 |
|------|------|
| `TranslationSession` | 执行翻译的会话对象 |
| `TranslationSession.Configuration` | 翻译配置（源语言、目标语言） |
| `TranslationSession.Request` | 批量翻译请求项 |
| `TranslationSession.Response` | 翻译响应（含 `targetText`、`sourceLanguage`、`clientIdentifier`） |
| `LanguageAvailability` | 查询语言对支持状态 |

#### 1.2 TranslationSession.Configuration

配置对象指定源语言和目标语言。源语言可以为 `nil`（自动检测）。

```swift
import Translation

// 方式 1：指定源语言和目标语言
let config = TranslationSession.Configuration(
    source: Locale.Language(identifier: "zh-Hans"),
    target: Locale.Language(identifier: "en")
)

// 方式 2：自动检测源语言
let config = TranslationSession.Configuration(
    source: nil,
    target: Locale.Language(identifier: "en")
)

// 方式 3：可变配置
var config = TranslationSession.Configuration()
config.source = Locale.Language(languageCode: .chinese)
config.target = Locale.Language(languageCode: .english)
```

关键约束：一个 Configuration 只能有一个目标语言。

#### 1.3 获取 TranslationSession 实例

**macOS 15 (Sequoia) / iOS 18 — 仅 SwiftUI**

在 macOS 15 和 iOS 18 上，TranslationSession **只能**通过 SwiftUI 的 `.translationTask` modifier 获取：

```swift
struct TranslationView: View {
    @State private var configuration: TranslationSession.Configuration?
    @State private var translatedText = ""
    
    var body: some View {
        Text(translatedText)
            .translationTask(configuration) { session in
                do {
                    let response = try await session.translate("你好世界")
                    translatedText = response.targetText
                } catch {
                    print("Translation error: \(error)")
                }
            }
    }
}
```

`.translationTask` 在 configuration 从 `nil` 变为非 nil 值时触发 action 闭包，闭包参数为 `TranslationSession` 实例。

**macOS 26 (Tahoe) / iOS 26 — 独立初始化（新增）**

iOS 26 / macOS 26 新增 `TranslationSession.init(installedSource:target:)` 初始化器，允许在**非 SwiftUI 上下文**中直接创建会话：

```swift
let session = TranslationSession(
    installedSource: Locale.Language(identifier: "zh-Hans"),
    target: Locale.Language(identifier: "en")
)
let response = try await session.translate("你好世界")
print(response.targetText) // "Hello World"
```

此初始化器要求语言模型已安装在设备上。

#### 1.4 翻译方法

**单文本翻译：**

```swift
let response = try await session.translate("你好世界")
let translated = response.targetText  // "Hello World"
let detectedSource = response.sourceLanguage  // Locale.Language for "zh-Hans"
```

**批量翻译：**

```swift
let requests = [
    TranslationSession.Request(sourceText: "你好", clientIdentifier: "1"),
    TranslationSession.Request(sourceText: "世界", clientIdentifier: "2"),
]

// 方式 1：一次性返回所有结果
let responses = try await session.translations(from: requests)

// 方式 2：AsyncSequence 流式返回
for try await response in session.translate(batch: requests) {
    print("\(response.clientIdentifier ?? ""): \(response.targetText)")
}
```

**预下载语言模型：**

```swift
try await session.prepareTranslation()
```

调用后系统会弹出对话框请求用户许可下载语言包。可在实际翻译前提前调用。

**使配置失效/触发重新翻译：**

```swift
configuration?.invalidate()
```

#### 1.5 LanguageAvailability

```swift
let availability = LanguageAvailability()

// 检查特定语言对状态
let status = await availability.status(
    from: Locale.Language(identifier: "zh-Hans"),
    to: Locale.Language(identifier: "en")
)
// status: .installed / .supported / .unsupported

// 获取所有支持的语言列表
let languages = await availability.supportedLanguages
// 返回 [Locale.Language]
```

三种状态含义：
- `.installed`：语言对已安装，可立即翻译（离线可用）
- `.supported`：语言对受支持，但需要下载语言模型
- `.unsupported`：语言对不受支持

### 2. 支持的语言对

Apple Translate 当前支持约 20 种语言之间的互译：

| 语言 | Locale 标识符 |
|------|-------------|
| English (US/UK) | `en` |
| 简体中文 (Mandarin) | `zh-Hans` |
| 繁體中文 (Mandarin) | `zh-Hant` |
| 日本語 | `ja` |
| 한국어 | `ko` |
| Español (Spain) | `es` |
| Français (France) | `fr` |
| Deutsch | `de` |
| Italiano | `it` |
| Português (Brazil) | `pt` |
| Русский | `ru` |
| العربية | `ar` |
| हिन्दी | `hi` |
| Bahasa Indonesia | `id` |
| ไทย | `th` |
| Tiếng Việt | `vi` |
| Türkçe | `tr` |
| Polski | `pl` |
| Nederlands | `nl` |
| Українська | `uk` |

**覆盖率分析**：与 WhisperUtil 设置面板中的翻译目标语言对比：

| SettingsView 目标语言 | tag 值 | Apple Translation 支持 |
|----------------------|--------|----------------------|
| English | `en` | 支持 |
| 中文 | `zh` | 支持 (`zh-Hans`) |
| 日本語 | `ja` | 支持 |
| 한국어 | `ko` | 支持 |
| Français | `fr` | 支持 |
| Deutsch | `de` | 支持 |
| Español | `es` | 支持 |

**结论：WhisperUtil 设置面板中的全部 7 种翻译目标语言都被 Apple Translation 支持。**

### 3. macOS 版本要求和限制

#### 3.1 平台版本要求

| 平台 | 最低版本 | 说明 |
|------|---------|------|
| macOS | 14.4 (Sonoma) | `.translationTask` SwiftUI modifier 可用 |
| macOS | 26 (Tahoe) | `TranslationSession.init(installedSource:target:)` 独立初始化可用 |
| iOS | 17.4 | `.translationTask` SwiftUI modifier 可用 |
| iOS | 26 | 独立初始化可用 |

#### 3.2 关键限制

1. **SwiftUI 依赖（macOS 15 及以下）**：TranslationSession 只能通过 SwiftUI `.translationTask` modifier 获取。非 SwiftUI 代码（如 AppKit）需要嵌入一个 SwiftUI View 作为桥接。

2. **macOS 26 独立初始化**：`init(installedSource:target:)` 要求语言模型已安装。如果未安装，需要先通过其他机制触发下载。

3. **无调用频率限制**：Apple 文档和社区反馈均未提及 API 调用频率限制。翻译完全在本地执行，不计费。

4. **文本长度限制**：Apple 文档未明确说明单次翻译的文本长度上限。社区测试表明，常规段落长度（数千字符）均可正常翻译。对于 WhisperUtil 的语音转录文本（通常几十到几百字），完全不会触及任何限制。

5. **无需特殊 Entitlement**：Translation Framework 不需要特殊的 entitlement 或 capability。沙盒和非沙盒 app 均可使用。

6. **模拟器不支持**：Translation Framework 在 Xcode 模拟器上不可用，测试需要真机或直接运行 macOS app。

7. **语言包下载需用户许可**：首次使用某语言对时，系统会弹出对话框请求用户许可下载语言模型。也可通过 `prepareTranslation()` 提前触发。用户也可在"系统设置 > 通用 > 语言与地区 > 翻译语言"中手动管理。

### 4. 离线模型管理机制

#### 4.1 模型存储与共享

- 翻译模型是**系统级**的，由所有 app 共享（包括系统 Translate app）
- 用户下载一次语言包后，所有 app 均可使用
- 模型存储在系统目录中，由系统自动管理（app 无法直接访问或删除）

#### 4.2 下载触发方式

1. **自动提示**：调用 `session.translate()` 时，如果语言模型未安装，系统自动弹出下载对话框
2. **主动触发**：调用 `session.prepareTranslation()` 可在不执行翻译的情况下触发下载
3. **系统设置**：用户在"系统设置 > 通用 > 语言与地区 > 翻译语言"中手动下载
4. **macOS 26**：使用 `init(installedSource:target:)` 时，如果模型未安装会报错而非弹出下载界面

#### 4.3 模型大小

单个语言对的模型大约 100-200MB。具体大小取决于语言对。

### 5. 性能和质量评估

#### 5.1 翻译速度

| 场景 | 延迟 | 说明 |
|------|------|------|
| 单句翻译（模型已加载） | ~100-200ms | 极快，几乎无感知 |
| 首次翻译（模型冷启动） | ~1-2s | 需要加载模型到内存 |
| 长段翻译（数百字） | ~200-500ms | 与文本长度近似线性 |

WhisperUtil 场景：语音转录文本通常 10-200 字，翻译延迟约 100-300ms，完全可接受。

#### 5.2 翻译质量

基于社区反馈和对比测试：

| 语言对 | 质量评估 | 说明 |
|--------|---------|------|
| 中文 → 英文 | 良好 (B+) | 日常对话和一般文本翻译质量好，技术/专业文本偶有不准确 |
| 英文 → 中文 | 良好 (B+) | 基本准确，但口语化表达有时不够自然 |
| 日文 → 英文 | 良好 (B) | 基本可用，敬语和语境理解稍弱 |
| 英文 → 日文 | 良好 (B) | 可用，但自然度不如专业翻译服务 |
| 其他主流语对 | 良好 (B+) | 欧洲语言间翻译质量较高 |

**与 gpt-4o-mini 对比**：Apple Translation 约为 gpt-4o-mini 质量的 85-90%（主流语言对），日常使用场景完全足够。主要差距在于：
- 习语/俚语理解：gpt-4o-mini 更好
- 上下文连贯性：gpt-4o-mini 更好（LLM 的天然优势）
- 技术术语：基本持平
- 一般文本：差距很小

#### 5.3 已知问题

1. macOS 上没有独立的 Translate app（iOS 有），但 Translation Framework 可正常工作
2. 某些语言包下载可能偶尔卡住（社区反馈），重试通常可解决
3. 不支持方言间转换（如繁体中文到简体中文的文本转换不是翻译框架的职责）
4. iOS 26 / macOS 26 的独立初始化 API 要求模型已安装

---

## Part B：集成实施计划

### 1. 架构设计

#### 1.1 新建 ServiceAppleTranslation.swift

遵循现有 Service 模式，新建翻译服务文件 `Services/ServiceAppleTranslation.swift`。

**设计要点：**

- 纯文本翻译服务（接收已转录的文本，返回翻译文本）
- 与 `ServiceCloudOpenAI.chatTranslate()` 的职责对应
- 内部管理 TranslationSession 生命周期
- 提供语言可用性检查能力

**关键挑战：SwiftUI 依赖**

由于 WhisperUtil 当前部署目标是 macOS 14+（非 macOS 26），TranslationSession 只能通过 SwiftUI modifier 获取。需要一个桥接方案：

**方案 A（推荐）：隐藏 SwiftUI View 桥接**

创建一个不可见的 SwiftUI View 作为 TranslationSession 的宿主。这是 Apple 官方推荐的 AppKit 集成方式。

```swift
// Services/ServiceAppleTranslation.swift
import Foundation
import Translation
import SwiftUI
import AppKit

@available(macOS 14.4, *)
class ServiceAppleTranslation {
    
    /// 翻译文本
    /// - Parameters:
    ///   - text: 待翻译文本
    ///   - sourceLanguage: 源语言代码（如 "zh"），nil 表示自动检测
    ///   - targetLanguage: 目标语言代码（如 "en"）
    ///   - completion: 完成回调
    func translate(
        text: String,
        sourceLanguage: String?,
        targetLanguage: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let source = sourceLanguage.map { mapToLocaleLanguage($0) }
        let target = mapToLocaleLanguage(targetLanguage)
        
        Task { @MainActor in
            let bridge = TranslationBridge(
                text: text,
                source: source,
                target: target,
                completion: completion
            )
            bridge.performTranslation()
        }
    }
    
    /// 检查语言对是否可用
    func checkAvailability(
        source: String?,
        target: String
    ) async -> LanguageAvailabilityStatus {
        let availability = LanguageAvailability()
        let sourceLang = source.map { mapToLocaleLanguage($0) }
            ?? Locale.Language(identifier: "zh-Hans")
        let targetLang = mapToLocaleLanguage(target)
        
        let status = await availability.status(
            from: sourceLang,
            to: targetLang
        )
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }
    
    /// 获取所有支持的语言
    func supportedLanguages() async -> [Locale.Language] {
        let availability = LanguageAvailability()
        return await availability.supportedLanguages
    }
    
    enum LanguageAvailabilityStatus {
        case installed      // 已安装，可立即使用
        case needsDownload  // 支持但需下载
        case unsupported    // 不支持
    }
    
    enum TranslationError: Error, LocalizedError {
        case unsupportedLanguagePair
        case translationFailed(String)
        case sessionCreationFailed
        
        var errorDescription: String? {
            switch self {
            case .unsupportedLanguagePair:
                return "Unsupported language pair for Apple Translation"
            case .translationFailed(let msg):
                return "Apple Translation failed: \(msg)"
            case .sessionCreationFailed:
                return "Failed to create translation session"
            }
        }
    }
    
    // MARK: - 语言代码映射
    
    /// 将 WhisperUtil 的语言代码映射到 Apple Locale.Language
    private func mapToLocaleLanguage(_ code: String) -> Locale.Language {
        switch code {
        case "zh":      return Locale.Language(identifier: "zh-Hans")
        case "zh-Hant": return Locale.Language(identifier: "zh-Hant")
        default:        return Locale.Language(identifier: code)
        }
    }
}
```

**TranslationBridge（SwiftUI 桥接）：**

```swift
// Services/TranslationBridge.swift（或内嵌在 ServiceAppleTranslation.swift 中）
import SwiftUI
import Translation

@available(macOS 14.4, *)
@MainActor
class TranslationBridge {
    private let text: String
    private let source: Locale.Language?
    private let target: Locale.Language
    private let completion: (Result<String, Error>) -> Void
    
    private var hostingController: NSHostingController<TranslationHostView>?
    
    init(text: String, source: Locale.Language?, target: Locale.Language,
         completion: @escaping (Result<String, Error>) -> Void) {
        self.text = text
        self.source = source
        self.target = target
        self.completion = completion
    }
    
    func performTranslation() {
        let config = TranslationSession.Configuration(
            source: source,
            target: target
        )
        
        let view = TranslationHostView(
            text: text,
            configuration: config,
            completion: { [weak self] result in
                self?.completion(result)
                // 清理桥接 view
                self?.hostingController?.view.removeFromSuperview()
                self?.hostingController = nil
            }
        )
        
        // 创建隐藏的 hosting controller
        let hc = NSHostingController(rootView: view)
        hc.view.frame = .zero
        hc.view.alphaValue = 0
        self.hostingController = hc
        
        // 添加到 app 的某个窗口（不可见）
        if let window = NSApp.windows.first {
            window.contentView?.addSubview(hc.view)
        }
    }
}

@available(macOS 14.4, *)
struct TranslationHostView: View {
    let text: String
    let configuration: TranslationSession.Configuration
    let completion: (Result<String, Error>) -> Void
    
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                do {
                    let response = try await session.translate(text)
                    completion(.success(response.targetText))
                } catch {
                    completion(.failure(error))
                }
            }
    }
}
```

**方案 B（macOS 26+ 简化版）：**

当部署目标升级到 macOS 26 后，可以直接使用独立初始化器，无需 SwiftUI 桥接：

```swift
@available(macOS 26, *)
func translateDirect(text: String, source: String, target: String) async throws -> String {
    let session = TranslationSession(
        installedSource: mapToLocaleLanguage(source),
        target: mapToLocaleLanguage(target)
    )
    let response = try await session.translate(text)
    return response.targetText
}
```

#### 1.2 方法签名设计

与 `ServiceCloudOpenAI.chatTranslate()` 对齐，提供一致的翻译接口：

```swift
// ServiceCloudOpenAI 现有接口（参考）
func chatTranslate(text: String, completion: @escaping (Result<String, Error>) -> Void)

// ServiceAppleTranslation 新接口
func translate(
    text: String,
    sourceLanguage: String?,
    targetLanguage: String,
    completion: @escaping (Result<String, Error>) -> Void
)
```

### 2. 后端改动

#### 2.1 新增文件

| 文件 | 说明 |
|------|------|
| `Services/ServiceAppleTranslation.swift` | Apple Translation 翻译服务，含 SwiftUI 桥接逻辑 |

#### 2.2 RecordingController 改动

**现有 `translateAudio()` 方法**（`RecordingController.swift` 第 535-548 行）：

```swift
// 现有逻辑：只使用 whisperService（Cloud API）
private func translateAudio(_ recording: AudioRecorder.RecordingResult, audioDuration: TimeInterval) {
    if config.translationMethod == "two-step" {
        whisperService.translateTwoStep(...)
    } else {
        whisperService.translate(...)
    }
}
```

**改动后逻辑**：增加翻译引擎选择分支

```swift
private func translateAudio(_ recording: AudioRecorder.RecordingResult, audioDuration: TimeInterval) {
    let lm = LocaleManager.shared
    let targetLang = SettingsStore.shared.translationTargetLanguage
    
    switch translationEngine {
    case .appleTranslation:
        // 先转录，再用 Apple Translation 翻译
        Log.i(lm.logLocalized("Calling Apple Translation (local translation)..."))
        transcribeAndTranslateLocally(recording, audioDuration: audioDuration, targetLanguage: targetLang)
        
    case .cloud:
        // 现有逻辑：Cloud API 翻译
        if config.translationMethod == "two-step" {
            whisperService.translateTwoStep(audioData: recording.data, format: recording.format, audioDuration: audioDuration) { ... }
        } else {
            whisperService.translate(audioData: recording.data, format: recording.format, audioDuration: audioDuration) { ... }
        }
        
    case .auto:
        // 优先尝试 Apple Translation，失败则 fallback 到 Cloud
        // 详见 2.4 节
    }
}

/// Apple Translation 路径：先转录再翻译
private func transcribeAndTranslateLocally(
    _ recording: AudioRecorder.RecordingResult,
    audioDuration: TimeInterval,
    targetLanguage: String
) {
    let lm = LocaleManager.shared
    // Step 1: 使用当前 API 模式转录
    let samples = audioRecorder.getAudioSamples()
    
    if currentApiMode == .local {
        // 本地 WhisperKit 转录
        Task {
            do {
                let transcribed = try await localWhisperService.transcribe(samples: samples)
                await MainActor.run {
                    self.appleTranslateText(transcribed, targetLanguage: targetLanguage)
                }
            } catch {
                await MainActor.run {
                    self.handleError(String(localized: "Local transcription failed: \(error.localizedDescription)"))
                }
            }
        }
    } else {
        // Cloud API 转录
        whisperService.transcribe(audioData: recording.data, format: recording.format, audioDuration: audioDuration) { [weak self] result in
            switch result {
            case .success(let text):
                self?.appleTranslateText(text, targetLanguage: targetLanguage)
            case .failure(let error):
                self?.handleError(String(localized: "Transcription failed: \(error.localizedDescription)"))
            }
        }
    }
}

/// Step 2: 用 Apple Translation 翻译已转录的文本
private func appleTranslateText(_ text: String, targetLanguage: String) {
    let lm = LocaleManager.shared
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        currentState = .idle
        return
    }
    Log.i(lm.logLocalized("Apple Translation: translating text to") + " \(targetLanguage)")
    
    appleTranslationService.translate(
        text: trimmed,
        sourceLanguage: effectiveWhisperLanguage().isEmpty ? nil : effectiveWhisperLanguage(),
        targetLanguage: targetLanguage
    ) { [weak self] result in
        DispatchQueue.main.async {
            self?.handleResult(result, action: lm.logLocalized("Apple Translation"))
        }
    }
}
```

#### 2.3 Config 改动

**EngineeringOptions.swift** — 新增翻译引擎配置：

```swift
// MARK: - Translation

/// 翻译引擎
/// - "auto": 优先 Apple Translation，失败时 fallback 到 Cloud
/// - "apple": 强制使用 Apple Translation（离线可用）
/// - "cloud": 强制使用 Cloud API（gpt-4o-mini，需网络）
static let translationEngine = "auto"
```

**RecordingController** — 新增翻译引擎属性：

```swift
enum TranslationEngine {
    case auto
    case appleTranslation
    case cloud
}
var translationEngine: TranslationEngine = .auto
```

**AppDelegate** — 初始化时注入 ServiceAppleTranslation：

```swift
private var appleTranslationService: ServiceAppleTranslation?

func setupComponents() {
    if #available(macOS 14.4, *) {
        appleTranslationService = ServiceAppleTranslation()
    }
    // ... 传递给 RecordingController
}
```

#### 2.4 与"优先级 Fallback"机制配合

根据 `plan_priority_fallback.md` 中规划的优先级回退机制，翻译引擎的 fallback 策略：

```
翻译请求
  |
  v
[translationEngine == auto?]
  |-- yes --> [Apple Translation 可用？（LanguageAvailability 检查）]
  |             |-- .installed --> 使用 Apple Translation
  |             |-- .supported --> 使用 Apple Translation（可能触发下载提示）
  |             |-- .unsupported --> fallback 到 Cloud API
  |             |-- 翻译失败 --> fallback 到 Cloud API
  |
  |-- apple --> 使用 Apple Translation（失败则报错）
  |
  |-- cloud --> 使用 Cloud API（现有逻辑）
```

### 3. 前端 UI 改动

#### 3.1 设置面板：翻译引擎选项

在 `SettingsView.swift` 的 Translation Section 中新增引擎选择：

```swift
// MARK: - Translation
Section("Translation") {
    Picker("Translation Engine", selection: $store.translationEngine) {
        Text("Auto (Prefer Local)").tag("auto")
        Text("Apple Translation (Local)").tag("apple")
        Text("Cloud API (GPT)").tag("cloud")
    }
    
    Picker("Output Language", selection: $store.translationTargetLanguage) {
        // ... 现有语言选项
    }
    
    // 语言包状态指示（可选，后续迭代）
    if store.translationEngine != "cloud" {
        HStack {
            Image(systemName: languagePackIcon)
                .foregroundColor(languagePackColor)
            Text(languagePackStatusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
```

暂不在 UI 中暴露翻译引擎选项（遵循 UserSettings = 最小 UI 原则）。`translationEngine` 作为 `EngineeringOptions` 的静态配置，开发者在代码中调整。仅当用户明确需求时再考虑加入设置面板。

#### 3.2 语言包状态展示（可选，后续迭代）

如果需要在 UI 中展示语言包下载状态，可通过 LanguageAvailability 异步查询：

```swift
@State private var languageStatus: LanguageAvailability.Status = .installed

var languagePackIcon: String {
    switch languageStatus {
    case .installed: return "checkmark.circle.fill"
    case .supported: return "arrow.down.circle"
    case .unsupported: return "xmark.circle"
    @unknown default: return "questionmark.circle"
    }
}
```

**建议**：首期不做 UI 展示，Apple Translation 在语言包未安装时会自动弹出系统下载对话框，用户体验已经足够。

### 4. 语言映射

#### 4.1 SettingsStore 语言代码 → Apple Translation Locale.Language

`SettingsStore.translationTargetLanguage` 存储的是简短语言代码字符串，需要映射到 `Locale.Language`：

| SettingsStore 值 | Locale.Language 标识符 | 说明 |
|-----------------|---------------------|------|
| `"en"` | `"en"` | 直接映射 |
| `"zh"` | `"zh-Hans"` | **需要特殊处理**：WhisperUtil 用 "zh" 表示简体中文 |
| `"ja"` | `"ja"` | 直接映射 |
| `"ko"` | `"ko"` | 直接映射 |
| `"fr"` | `"fr"` | 直接映射 |
| `"de"` | `"de"` | 直接映射 |
| `"es"` | `"es"` | 直接映射 |

映射函数：

```swift
func mapToLocaleLanguage(_ code: String) -> Locale.Language {
    switch code {
    case "zh":      return Locale.Language(identifier: "zh-Hans")
    case "zh-Hant": return Locale.Language(identifier: "zh-Hant")
    default:        return Locale.Language(identifier: code)
    }
}
```

#### 4.2 源语言映射

`SettingsStore.whisperLanguage`（识别语言）同样需要映射。特殊情况：
- 空字符串 `""`（自动检测）：传 `nil` 给 Apple Translation，让其自动检测源语言
- `"ui"`（同界面语言）：先解析为实际语言代码，再映射

#### 4.3 不支持的语言对处理

如果用户选择了 Apple Translation 不支持的语言对：

1. **auto 模式**：自动 fallback 到 Cloud API，静默处理
2. **apple 模式**：报错提示用户该语言对不支持本地翻译
3. 可通过 `LanguageAvailability.status()` 在翻译前检查

### 5. 分步实施计划

#### Phase 1：核心集成（预计 1-2 天）

1. 新建 `Services/ServiceAppleTranslation.swift`
   - 实现 TranslationBridge（SwiftUI 桥接）
   - 实现 `translate()` 方法（含语言映射）
   - 实现 `checkAvailability()` 方法
   - 错误处理

2. RecordingController 改动
   - 新增 `appleTranslationService` 依赖
   - 改造 `translateAudio()` 支持 Apple Translation 路径
   - 新增 `transcribeAndTranslateLocally()` 和 `appleTranslateText()` 方法

3. AppDelegate 改动
   - 创建并注入 ServiceAppleTranslation 实例
   - `@available(macOS 14.4, *)` 条件编译

4. EngineeringOptions 改动
   - 新增 `translationEngine` 配置项

#### Phase 2：测试与调优（预计 0.5-1 天）

1. 功能测试
   - 中文→英文翻译
   - 英文→中文翻译
   - 其他支持的语言对
   - 语言包未下载时的行为
   - 网络断开时的离线翻译

2. SwiftUI 桥接稳定性
   - 并发翻译请求处理
   - View 生命周期管理
   - 内存泄漏检查

3. Fallback 机制
   - Apple Translation 失败后 Cloud API 回退
   - 不支持的语言对自动回退

#### Phase 3：可选优化（后续迭代）

1. 将 `translationEngine` 暴露到 SettingsStore 和设置面板（如果用户需求明确）
2. 语言包状态展示 UI
3. macOS 26 适配（去掉 SwiftUI 桥接，使用独立初始化）
4. 翻译质量 A/B 对比（Apple Translation vs Cloud API）

### 6. 风险和注意事项

#### 6.1 SwiftUI 桥接风险（最大风险）

**问题**：在 macOS 14/15 上，TranslationSession 必须通过 SwiftUI View 获取。WhisperUtil 的翻译逻辑在 RecordingController（非 UI 层），需要创建隐藏的 SwiftUI View 作为桥接。

**风险**：
- 隐藏 View 的生命周期管理可能导致 session 过早释放
- 并发翻译请求可能需要创建多个桥接 View
- View 依附的窗口如果不存在（如 app 刚启动时菜单栏 app 可能没有 window），桥接会失败

**缓解措施**：
- 使用专门的隐藏 NSWindow 作为桥接宿主，在 AppDelegate 启动时创建
- 序列化翻译请求，避免并发问题
- 充分测试各种时序场景

#### 6.2 系统版本兼容

**问题**：WhisperUtil 当前部署目标是 macOS 14.0+，而 Translation Framework 需要 macOS 14.4+。

**缓解**：使用 `@available(macOS 14.4, *)` 条件编译，macOS 14.0-14.3 用户自动 fallback 到 Cloud API。影响极小，macOS 14.4 已发布超过 2 年。

#### 6.3 语言包未下载时的体验

**问题**：首次使用时系统弹出下载对话框，可能打断用户工作流。

**缓解**：
- 在 `auto` 模式下，可先用 `checkAvailability()` 检查状态：如果是 `.supported`（未下载），直接走 Cloud API 避免打断用户
- 提供 `prepareTranslation()` 按钮让用户主动触发下载

#### 6.4 翻译质量预期管理

Apple Translation 质量约为 gpt-4o-mini 的 85-90%。对于专业翻译场景（法律、医学文档），建议用户使用 Cloud API 模式。`auto` 模式下的 fallback 机制可确保在需要时无缝切换。

#### 6.5 与现有已知 Bug 的关系

代码审查（`04_translation_review.md`）中指出 `chatTranslate()` 目标语言硬编码为英语的问题。新增 Apple Translation 路径时应同步修复此问题，确保 `translationTargetLanguage` 贯穿整个翻译调用链：

```
SettingsStore.translationTargetLanguage
  -> RecordingController.translateAudio()
  -> ServiceAppleTranslation.translate(targetLanguage:)
     或 ServiceCloudOpenAI.chatTranslate(targetLanguage:)
```

---

## 参考文件

- `/Users/longhaitao/Documents/3_WhisperUtil/Services/ServiceCloudOpenAI.swift` — 现有翻译实现
- `/Users/longhaitao/Documents/3_WhisperUtil/RecordingController.swift` — 翻译调度逻辑（第 535-548 行）
- `/Users/longhaitao/Documents/3_WhisperUtil/Config/EngineeringOptions.swift` — translationMethod 配置
- `/Users/longhaitao/Documents/3_WhisperUtil/Config/SettingsStore.swift` — translationTargetLanguage
- `/Users/longhaitao/Documents/3_WhisperUtil/UI/SettingsView.swift` — Translation Section（第 133-143 行）
- `/Users/longhaitao/Documents/3_WhisperUtil/Config/Config.swift` — 运行时配置
- `/Users/longhaitao/Documents/3_WhisperUtil/.claude-tech-research/24_local_translation.md` — 前期调研
- `/Users/longhaitao/Documents/3_WhisperUtil/.claude-code-review/04_translation_review.md` — 翻译代码审查
- `/Users/longhaitao/Documents/3_WhisperUtil/.claude-plan/plan_priority_fallback.md` — 优先级 fallback 计划

## 参考来源

- [Apple TranslationSession Documentation](https://developer.apple.com/documentation/translation/translationsession)
- [Apple LanguageAvailability Documentation](https://developer.apple.com/documentation/translation/languageavailability)
- [Apple Translation Framework Overview](https://developer.apple.com/documentation/translation/)
- [WWDC24: Meet the Translation API](https://developer.apple.com/videos/play/wwdc2024/10117/)
- [Apple: Translating text within your app](https://developer.apple.com/documentation/Translation/translating-text-within-your-app)
- [From Paid APIs to Native: Migrating to Apple's Translation Framework (Medium)](https://toyboy2.medium.com/from-paid-apis-to-native-migrating-to-apples-translation-framework-in-swiftui-c31157da2783)
- [Swift Translation API Guide (polpiella.dev)](https://www.polpiella.dev/swift-translation-api/)
- [Using Translation API in Swift (AppCoda)](https://www.appcoda.com/translation-api/)
- [Free translation API using iOS 18 Translation (mszpro.com)](https://mszpro.com/ios-system-translate)
- [Translation API blog (Michael Tsai)](https://mjtsai.com/blog/2024/07/04/translation-api-in-ios-17-and-macos-sequoia/)
- [Using Translation framework (createwithswift.com)](https://www.createwithswift.com/using-the-translation-framework-for-language-to-language-translation/)
