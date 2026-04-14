# WhisperUtil UI 国际化 (i18n) 调研报告

## Part 1: 硬编码字符串审计

### 1.1 SettingsView.swift — SwiftUI 设置面板

| # | 字符串 | 类型 |
|---|--------|------|
| 1 | `"语言"` | Section 标题 |
| 2 | `"识别语言"` | Picker 标签 |
| 3 | `"自动检测"` | Picker 选项 |
| 4 | `"中文"` | Picker 选项 |
| 5 | `"转写"` | Section 标题 |
| 6 | `"默认 API 模式"` | Picker 标签 |
| 7 | `"本地识别 (WhisperKit)"` | Picker 选项 |
| 8 | `"网络 API"` | Picker 选项 |
| 9 | `"实时 API"` | Picker 选项 |
| 10 | `"文本优化"` | Picker 标签 |
| 11 | `"关闭"` | Picker 选项 |
| 12 | `"自然润色"` | Picker 选项 |
| 13 | `"正式风格"` | Picker 选项 |
| 14 | `"口语风格"` | Picker 选项 |
| 15 | `"翻译"` | Section 标题 |
| 16 | `"输出语言"` | Picker 标签 |
| 17 | `"通用"` | Section 标题 |
| 18 | `"发送模式"` | Picker 标签 |
| 19 | `"仅转写"` | Picker 选项 |
| 20 | `"转写+自动发送"` | Picker 选项 |
| 21 | `"转写+延迟发送"` | Picker 选项 |
| 22 | `"延迟时间: \(Int(...)) 秒"` | Stepper 标签（含动态值） |
| 23 | `"播放提示音"` | Toggle 标签 |

**小计: 23 个字符串**

### 1.2 StatusBarController.swift — 菜单栏 UI

| # | 字符串 | 类型 |
|---|--------|------|
| 1 | `"🎤 开始转录 (⌥)"` | 菜单项标题 |
| 2 | `"🌐 开始翻译 (⌥⌥)"` | 菜单项标题 |
| 3 | `"复制并粘贴上次转写:"` | 菜单项标题（静态提示） |
| 4 | `"  (无)"` | 菜单项标题（无转写时） |
| 5 | `"设置..."` | 菜单项标题 |
| 6 | `"关于 WhisperUtil"` | 菜单项标题 |
| 7 | `"退出"` | 菜单项标题 |
| 8 | `"⏹ 停止录音"` | 录音中状态 |
| 9 | `"⏳ 处理中..."` | 处理中状态 |
| 10 | `"⏳ 等待发送... (单击⌥取消)"` | 等待发送状态 |
| 11 | `"关于 WhisperUtil"` (alert.messageText) | 关于对话框标题 |
| 12 | `"版本 1.0.0\n\n语音转文字 & 翻译工具\n..."` | 关于对话框内容（多行） |
| 13 | `"确定"` | 关于对话框按钮 |
| 14 | `"仅转写"` (AutoSendMode.displayName) | 枚举显示名 |
| 15 | `"转写+自动发送"` | 枚举显示名 |
| 16 | `"转写+延迟发送"` | 枚举显示名 |

**小计: 16 个字符串**（去重后约 14 个唯一字符串）

### 1.3 SettingsWindowController.swift — 设置窗口

| # | 字符串 | 类型 |
|---|--------|------|
| 1 | `"WhisperUtil 设置"` | 窗口标题 |

**小计: 1 个字符串**

### 1.4 RecordingController.swift — 核心调度器（用户可见的错误消息）

| # | 字符串 | 类型 |
|---|--------|------|
| 1 | `"麦克风正被其他应用使用，请先关闭其他语音输入程序"` | 错误消息 (handleError) |
| 2 | `"WhisperKit 模型正在加载中，请稍候..."` | 提示消息 (onError) |
| 3 | `"WhisperKit 模型尚未加载，请稍候再试"` | 提示消息 (onError) |
| 4 | `"录音启动失败: ..."` | 错误消息 (handleError) |
| 5 | `"实时转录错误: ..."` | 错误消息 (handleError) |
| 6 | `"WebSocket 连接断开"` | 错误消息 (handleError) |
| 7 | `"网络 API 失败，且无法回退到本地转录"` | 错误消息 (handleError) |
| 8 | `"网络 API 超时，已自动切换到本地识别"` | 提示消息 (onError) |
| 9 | `"...超时，请尝试缩短录音时长"` | 错误消息（动态前缀） |
| 10 | `"...失败: ..."` | 错误消息（动态前缀+后缀） |

**小计: 10 个字符串**

### 1.5 AppDelegate.swift — 通知消息

| # | 字符串 | 类型 |
|---|--------|------|
| 1 | `"正在加载语音识别模型，首次使用需下载..."` | 通知消息 |
| 2 | `"模型加载完成，本地识别已就绪"` | 通知消息 |
| 3 | `"模型加载失败: ..."` | 通知消息 |
| 4 | `"网络已恢复，已切回网络 API"` | 通知消息 |

**小计: 4 个字符串**

### 1.6 ServiceTextCleanup.swift — TextCleanupMode 枚举

| # | 字符串 | 类型 |
|---|--------|------|
| 1 | `"关闭"` | displayName |
| 2 | `"自然润色"` | displayName |
| 3 | `"正式风格"` | displayName |
| 4 | `"口语风格"` | displayName |

**小计: 4 个字符串**（与 SettingsView 重复，但代码位置不同）

### 1.7 AudioRecorder.swift — 错误描述

| # | 字符串 | 类型 |
|---|--------|------|
| 1 | `"麦克风权限被拒绝，请在系统设置中授权"` | 错误描述 |
| 2 | `"音频引擎创建失败"` | 错误描述 |
| 3 | `"音频格式创建失败"` | 错误描述 |
| 4 | `"麦克风正被其他应用使用，请先关闭其他语音输入程序"` | 错误描述 |

**小计: 4 个字符串**

### 1.8 ServiceLocalWhisper.swift — 错误描述

| # | 字符串 | 类型 |
|---|--------|------|
| 1 | `"WhisperKit 模型尚未加载，请稍候"` | 错误描述 |
| 2 | `"没有音频数据可供转录"` | 错误描述 |
| 3 | `"本地转录失败: ..."` | 错误描述 |

**小计: 3 个字符串**

### 1.9 ServiceCloudOpenAI.swift / ServiceRealtimeOpenAI.swift — 错误描述

| # | 字符串 | 类型 |
|---|--------|------|
| 1 | `"网络错误: ..."` | 错误描述 |
| 2 | `"无效的响应"` | 错误描述 |
| 3 | `"没有返回数据"` | 错误描述 |
| 4 | `"API 错误 (...): ..."` | 错误描述 |
| 5 | `"响应解码失败"` | 错误描述 |
| 6 | `"无效的 WebSocket URL"` | 错误描述 |
| 7 | `"Realtime API 错误: ..."` | 错误描述 |

**小计: 7 个字符串**

### 总计

| 分类 | 数量 |
|------|------|
| UI 标签（菜单、设置面板） | ~38 |
| 错误消息 | ~24 |
| 通知消息 | ~4 |
| 仅日志（Log.i/d/w/e，用户不可见） | ~80+ |
| **需本地化的字符串总计** | **~66** |

注意：`Log.i()/Log.w()/Log.e()/Log.d()` 中的字符串是开发者调试日志，不面向用户，**不需要本地化**。

---

## Part 2: macOS 本地化机制

### 2.1 NSLocalizedString 与 String(localized:)

**传统方式 -- NSLocalizedString（AppKit/UIKit）：**

```swift
let title = NSLocalizedString("settings_title", comment: "Settings window title")
// 或带默认值：
let title = NSLocalizedString("settings_title", value: "设置", comment: "Settings window title")
```

**现代方式 -- String(localized:)（Swift 5.7+/iOS 16+/macOS 13+）：**

```swift
let title = String(localized: "settings_title")
// 带默认值和注释：
let title = String(localized: "Settings", defaultValue: "设置", comment: "Settings window title")
```

对于 AppKit 的 `NSMenuItem`，使用 `NSLocalizedString` 或 `String(localized:)` 均可。

### 2.2 本地化资源文件格式

**1. .strings 文件（传统）：**

```
/* Settings window title */
"settings_title" = "WhisperUtil 设置";
```
- 手动维护，容易出错（少分号、引号不匹配）
- 每种语言一个文件：`zh-Hans.lproj/Localizable.strings`

**2. .stringsdict 文件（复数处理）：**
- XML/plist 格式，处理复数变化（如 "1 item" vs "3 items"）
- 本项目暂不需要复数处理

**3. String Catalogs -- .xcstrings（Xcode 15+，推荐）：**
- JSON 格式，Xcode 内置可视化编辑器
- 自动提取源码中的本地化字符串
- 支持状态追踪（New/Needs Review/Translated/Stale）
- 支持复数、设备变体
- 单文件管理所有语言的翻译

### 2.3 推荐方案：String Catalogs (.xcstrings)

**理由：**
1. **WhisperUtil 使用 Xcode 构建**，String Catalogs 与 Xcode 深度集成
2. **字符串数量约 66 个**，单文件管理清晰高效
3. **自动提取**：Xcode 编译时自动发现 `Text("...")` 和 `String(localized:)` 中的字符串
4. **可视化编辑**：无需手动编辑 JSON，Xcode 提供表格式 UI
5. **状态追踪**：新增/修改的字符串自动标记为"需翻译"
6. **向后兼容**：编译后生成传统 .strings 文件，运行时行为一致

### 2.4 Xcode 管理本地化文件

1. Project Settings -> Info -> Localizations -> 添加语言
2. Xcode 自动创建 `*.lproj/` 目录
3. String Catalog 方式下只需一个 `Localizable.xcstrings` 文件

### 2.5 目录结构

```
WhisperUtil/
├── Localizable.xcstrings          # String Catalog（所有语言的翻译）
├── en.lproj/                      # 英语资源（Storyboard 等）
│   └── Main.storyboard
├── zh-Hans.lproj/                 # 简体中文资源
│   └── Main.strings               # Storyboard 本地化（如需）
├── zh-Hant.lproj/                 # 繁体中文资源
├── ja.lproj/                      # 日语资源
└── Assets.xcassets                # 图片资源（通常无需本地化）
```

使用 String Catalogs 时，**不需要为每种语言创建 Localizable.strings**，所有翻译都在 `Localizable.xcstrings` 一个文件中。

---

## Part 3: 自动语言检测

### 3.1 macOS 语言检测机制

**是的，macOS 原生支持自动语言检测，无需任何代码。** 只要本地化文件正确配置，系统会自动根据用户语言偏好显示对应语言的 UI。

### 3.2 工作原理

macOS 启动应用时的语言选择流程：

```
1. 应用自身的语言设置（macOS Settings -> Language & Region -> Applications -> WhisperUtil）
   ↓ 如未设置
2. 系统全局首选语言列表（macOS Settings -> Language & Region -> Preferred Languages）
   ↓ 按列表顺序匹配
3. 应用 Bundle 中支持的语言列表（Info.plist -> CFBundleLocalizations）
   ↓ 取第一个匹配项
4. 开发语言（CFBundleDevelopmentRegion，通常 "en"）
   ↓ 最终兜底
```

### 3.3 关键 API

```swift
// 当前系统语言
Locale.current.language.languageCode  // e.g., "zh", "en", "ja"

// 应用实际使用的语言（已匹配 Bundle 支持的语言）
Bundle.main.preferredLocalizations.first  // e.g., "zh-Hans"

// 应用支持的所有语言
Bundle.main.localizations  // e.g., ["en", "zh-Hans", "zh-Hant", "ja"]
```

### 3.4 自动生效的条件

只需满足以下条件，语言切换**完全自动**：

1. Xcode 项目中添加了目标语言（Project -> Info -> Localizations）
2. 创建了 String Catalog 并填写了翻译
3. UI 代码使用了本地化字符串（`Text("key")` 或 `NSLocalizedString`）

**无需编写任何语言检测/切换代码。** macOS 框架在应用启动时自动完成。

### 3.5 应用级语言覆盖

用户可在不修改系统语言的情况下，为 WhisperUtil 单独设置语言：

- **macOS 13+**：系统设置 -> 通用 -> 语言与地区 -> 应用程序 -> 添加 WhisperUtil -> 选择语言
- **命令行测试**：`-AppleLanguages "(ja)"` 启动参数

```bash
# 测试日语 UI
open WhisperUtil.app --args -AppleLanguages "(ja)"
```

### 3.6 Xcode 调试

在 Scheme -> Run -> Options -> App Language 中可选择测试语言，无需修改系统设置。

---

## Part 4: SwiftUI 特定本地化

### 4.1 SwiftUI Text 的自动本地化

SwiftUI 的 `Text` 视图接收 `LocalizedStringKey`，**默认自动查找本地化翻译**：

```swift
// 这行代码自动在 String Catalog 中查找 "语言" 的翻译
Text("语言")

// 等价于
Text(LocalizedStringKey("语言"))
```

**重要：** 当前 WhisperUtil 的 SettingsView 中的 `Text("...")` 已经符合 SwiftUI 自动本地化的格式。只需创建 String Catalog 并添加翻译，**无需修改 Text 调用方式**。

### 4.2 Picker / Toggle / Section 标签

SwiftUI 的 `Section`、`Picker`、`Toggle` 的标签参数同样接收 `LocalizedStringKey`：

```swift
// 这些都会自动查找翻译
Section("语言") { ... }                              // 自动本地化
Picker("识别语言", selection: ...) { ... }            // 自动本地化
Toggle("播放提示音", isOn: ...) { ... }               // 自动本地化
Stepper("延迟时间: \(value) 秒", ...)                 // 插值字符串也支持
```

**Stepper 的插值字符串本地化：**

```swift
// "延迟时间: 5 秒" 在 String Catalog 中的 key 为：
// "延迟时间: %lld 秒"
// 英语翻译："Delay: %lld seconds"
```

SwiftUI 自动将 `\(Int(...))` 转换为 `%lld` 格式说明符。

### 4.3 环境语言覆盖（预览用）

```swift
#Preview {
    SettingsView(store: SettingsStore.shared)
        .environment(\.locale, Locale(identifier: "en"))  // 英语预览
}

#Preview {
    SettingsView(store: SettingsStore.shared)
        .environment(\.locale, Locale(identifier: "ja"))  // 日语预览
}
```

### 4.4 RTL 语言注意事项

如果未来需要支持阿拉伯语/希伯来语：
- SwiftUI 的 `Form`、`HStack` 等布局自动翻转
- 图标位置自动镜像
- 目前 WhisperUtil 无 RTL 需求（中/英/日目标语言都是 LTR）

### 4.5 AppKit 部分的本地化（NSMenuItem）

StatusBarController 使用 AppKit 的 `NSMenuItem`，不享受 SwiftUI 自动本地化。需要手动使用 `NSLocalizedString` 或 `String(localized:)`：

```swift
// 当前代码
transcribeMenuItem = NSMenuItem(title: "🎤 开始转录 (⌥)", ...)

// 本地化后
transcribeMenuItem = NSMenuItem(
    title: String(localized: "🎤 Start Transcription (⌥)"),
    ...
)
// 或使用语义化 key：
transcribeMenuItem = NSMenuItem(
    title: String(localized: "menu.transcribe.start"),
    ...
)
```

---

## Part 5: 实施计划

### Step 1: 在 Xcode 项目中启用本地化

1. 打开 `WhisperUtil.xcodeproj`
2. 选择项目（非 target） -> Info 标签
3. 在 Localizations 区域，点击 "+" 添加语言：
   - English (en) -- **设为开发语言 / Base language**
   - Chinese, Simplified (zh-Hans)
   - Chinese, Traditional (zh-Hant)
   - Japanese (ja)
4. 确保 `CFBundleDevelopmentRegion` 设为 `en`

### Step 2: 创建 String Catalog

1. File -> New -> File -> String Catalog
2. 命名为 `Localizable.xcstrings`
3. 放在 `WhisperUtil/` 资源目录下
4. 确保 target membership 包含 WhisperUtil

### Step 3: 替换硬编码字符串

**3a. SettingsView.swift -- 无需修改（SwiftUI 自动本地化）**

SwiftUI 的 `Text("...")` 编译时自动提取到 String Catalog。但建议将中文字面值改为英文语义 key，以便维护：

```swift
// 修改前（可工作，但 key 是中文，不利于多语言维护）
Section("语言") { ... }

// 修改后（推荐：用英文 key）
Section("Language") { ... }
```

> 注意：使用中文作为 key 也完全可以工作。String Catalog 会以原始字符串作为 key，各语言提供翻译即可。选择英文 key 的好处是当开发语言为英文时，未翻译的语言至少显示英文而非中文。

**3b. StatusBarController.swift -- 需要修改**

所有 `NSMenuItem` 的 `title` 参数需包裹 `String(localized:)`：

```swift
// 修改示例
transcribeMenuItem = NSMenuItem(
    title: String(localized: "🎤 Start Transcription (⌥)"),
    action: #selector(transcribeClicked),
    keyEquivalent: ""
)
```

**updateState() 中的动态标题也需要修改：**

```swift
case .recording:
    self.transcribeMenuItem.title = String(localized: "⏹ Stop Recording")
case .processing:
    self.transcribeMenuItem.title = String(localized: "⏳ Processing...")
case .waitingToSend:
    self.transcribeMenuItem.title = String(localized: "⏳ Waiting to Send... (tap ⌥ to cancel)")
```

**showAbout() 对话框：**

```swift
alert.messageText = String(localized: "About WhisperUtil")
alert.informativeText = String(localized: "about_dialog_body")  // 多行内容用 key
alert.addButton(withTitle: String(localized: "OK"))
```

**AutoSendMode.displayName：**

```swift
var displayName: String {
    switch self {
    case .off: return String(localized: "Transcribe Only")
    case .always: return String(localized: "Transcribe + Auto Send")
    case .smart: return String(localized: "Transcribe + Delayed Send")
    }
}
```

**3c. SettingsWindowController.swift -- 修改窗口标题**

```swift
window.title = String(localized: "WhisperUtil Settings")
```

**3d. RecordingController.swift -- 错误消息**

```swift
handleError(String(localized: "Microphone is in use by another app. Please close other voice input programs first."))
```

对于含动态参数的错误消息：

```swift
// 使用 String(localized:) + 插值
handleError(String(localized: "Recording failed: \(error.localizedDescription)"))
// String Catalog key: "Recording failed: \(error.localizedDescription)"
// 实际使用格式说明符: "Recording failed: %@"
```

**3e. AppDelegate.swift -- 通知消息**

```swift
statusBarController.showNotification(
    title: "WhisperKit",
    message: String(localized: "Loading speech recognition model, first use requires download...")
)
```

**3f. ServiceTextCleanup.swift -- TextCleanupMode.displayName**

```swift
var displayName: String {
    switch self {
    case .off: return String(localized: "Off")
    case .neutral: return String(localized: "Natural")
    case .formal: return String(localized: "Formal")
    case .casual: return String(localized: "Casual")
    }
}
```

**3g. AudioRecorder.swift / ServiceLocalWhisper.swift -- 错误描述**

```swift
case .permissionDenied:
    return String(localized: "Microphone permission denied. Please authorize in System Settings.")
case .modelNotLoaded:
    return String(localized: "WhisperKit model not loaded yet, please wait")
```

### Step 4: 在 String Catalog 中添加翻译

Build 项目后，Xcode 自动提取所有 `String(localized:)` 和 SwiftUI `Text("...")` 中的字符串到 `Localizable.xcstrings`。

然后在 Xcode 的 String Catalog 编辑器中逐一填写翻译：

**示例翻译（部分）：**

| Key (English) | zh-Hans | zh-Hant | ja |
|---|---|---|---|
| Language | 语言 | 語言 | 言語 |
| Recognition Language | 识别语言 | 辨識語言 | 認識言語 |
| Auto Detect | 自动检测 | 自動偵測 | 自動検出 |
| Chinese | 中文 | 中文 | 中国語 |
| Transcription | 转写 | 轉寫 | 文字起こし |
| Default API Mode | 默认 API 模式 | 預設 API 模式 | デフォルト API モード |
| Local (WhisperKit) | 本地识别 (WhisperKit) | 本機辨識 (WhisperKit) | ローカル (WhisperKit) |
| Cloud API | 网络 API | 網路 API | クラウド API |
| Realtime API | 实时 API | 即時 API | リアルタイム API |
| Text Cleanup | 文本优化 | 文字優化 | テキスト最適化 |
| Off | 关闭 | 關閉 | オフ |
| Natural | 自然润色 | 自然潤色 | ナチュラル |
| Formal | 正式风格 | 正式風格 | フォーマル |
| Casual | 口语风格 | 口語風格 | カジュアル |
| Translation | 翻译 | 翻譯 | 翻訳 |
| Output Language | 输出语言 | 輸出語言 | 出力言語 |
| General | 通用 | 一般 | 一般 |
| Send Mode | 发送模式 | 傳送模式 | 送信モード |
| Transcribe Only | 仅转写 | 僅轉寫 | 文字起こしのみ |
| Transcribe + Auto Send | 转写+自动发送 | 轉寫+自動傳送 | 文字起こし+自動送信 |
| Transcribe + Delayed Send | 转写+延迟发送 | 轉寫+延遲傳送 | 文字起こし+遅延送信 |
| Delay: %lld seconds | 延迟时间: %lld 秒 | 延遲時間: %lld 秒 | 遅延: %lld 秒 |
| Play Sound Effects | 播放提示音 | 播放提示音 | サウンド効果を再生 |
| Settings... | 设置... | 設定... | 設定... |
| Quit | 退出 | 結束 | 終了 |
| OK | 确定 | 確定 | OK |

### Step 5: 测试不同语言环境

**方法 1 -- Xcode Scheme：**
Edit Scheme -> Run -> Options -> App Language -> 选择语言

**方法 2 -- 命令行：**
```bash
# 测试英语
open WhisperUtil.app --args -AppleLanguages "(en)"

# 测试日语
open WhisperUtil.app --args -AppleLanguages "(ja)"

# 测试繁体中文
open WhisperUtil.app --args -AppleLanguages "(zh-Hant)"
```

**方法 3 -- 系统设置：**
系统设置 -> 通用 -> 语言与地区 -> 修改首选语言 -> 重启应用

### Step 6: 处理动态字符串

**含插值的字符串（如 Stepper 标签）：**

```swift
// SwiftUI 自动处理
Stepper("Delay: \(Int(store.smartModeWaitDuration)) seconds", ...)
// String Catalog 中 key 为 "Delay: %lld seconds"
// zh-Hans 翻译: "延迟时间: %lld 秒"
```

**含动态错误信息的组合字符串：**

```swift
// 方案 A：整句本地化（推荐）
handleError(String(localized: "Recording failed: \(error.localizedDescription)"))
// String Catalog key: "Recording failed: %@"

// 方案 B：拼接（不推荐，语序可能因语言而异）
handleError(String(localized: "Recording failed") + ": " + error.localizedDescription)
```

推荐方案 A，因为不同语言中错误描述的位置可能不同。

**注意：** `error.localizedDescription` 本身来自系统或第三方库，其翻译不受 WhisperUtil 控制。但基础系统错误（如网络超时）macOS 已自带多语言翻译。

---

## Part 6: 工作量估算

### 6.1 字符串统计

| 分类 | 数量 |
|------|------|
| UI 标签（SettingsView） | 23 |
| 菜单项（StatusBarController） | 14 |
| 窗口标题（SettingsWindowController） | 1 |
| 错误消息（RecordingController） | 10 |
| 通知消息（AppDelegate） | 4 |
| 枚举 displayName（TextCleanupMode, AutoSendMode） | 7 |
| 错误描述（AudioRecorder, ServiceLocalWhisper, ServiceCloudOpenAI） | 14 |
| **合计（去重后）** | **~60-66** |

### 6.2 代码修改时间

| 任务 | 预计时间 |
|------|----------|
| Xcode 项目配置（添加语言、创建 String Catalog） | 15 分钟 |
| SettingsView.swift 修改（SwiftUI 部分，几乎无需改动） | 15 分钟 |
| StatusBarController.swift 修改（NSMenuItem 包裹 String(localized:)） | 30 分钟 |
| SettingsWindowController.swift 修改 | 5 分钟 |
| RecordingController.swift 修改（错误消息） | 30 分钟 |
| AppDelegate.swift 修改（通知消息） | 15 分钟 |
| 枚举 displayName 修改 | 10 分钟 |
| AudioRecorder / Service 错误描述修改 | 20 分钟 |
| **代码修改小计** | **~2.5 小时** |

### 6.3 翻译时间

| 任务 | 预计时间 |
|------|----------|
| 简体中文（已有，作为参考/验证） | 30 分钟 |
| 繁体中文 | 1 小时 |
| 英语 | 1 小时 |
| 日语 | 1 小时 |
| **翻译小计** | **~3.5 小时** |

### 6.4 测试时间

| 任务 | 预计时间 |
|------|----------|
| 各语言 UI 检查（4 种语言 x 15 分钟） | 1 小时 |
| 文本截断/布局问题修复 | 30 分钟 |
| 错误流程测试 | 30 分钟 |
| **测试小计** | **~2 小时** |

### 6.5 总计

| | 时间 |
|---|------|
| 代码修改 | 2.5 小时 |
| 翻译 | 3.5 小时 |
| 测试 | 2 小时 |
| **总计** | **~8 小时（1 个工作日）** |

### 6.6 AI 辅助翻译

**可以使用 Claude/GPT 辅助翻译。** 具体方式：

1. **导出 String Catalog 为 JSON**：`.xcstrings` 本身就是 JSON 格式，可以直接提供给 AI
2. **批量翻译**：将所有英文 key 和中文原文提供给 AI，要求翻译为目标语言
3. **质量注意事项**：
   - AI 翻译质量对于 UI 短文本（按钮、标签、菜单项）通常足够好
   - 技术术语需要人工审核（如 "转写" vs "文字起こし"）
   - 建议请母语使用者做最终 review
4. **工作流**：AI 翻译初稿（节省 70% 时间） -> 人工审核 -> 填入 String Catalog

使用 AI 辅助后，翻译时间可从 3.5 小时降至约 1.5 小时（含审核）。

---

## 附录：关键决策建议

1. **开发语言建议设为英语**：这样未翻译的语言 fallback 到英文（而非中文乱码），更加国际化
2. **Key 命名策略**：建议使用英文自然语言作为 key（如 `"Start Transcription (⌥)"`），而非命名空间 key（如 `"menu.transcribe.start"`），因为 SwiftUI 的 `Text("...")` 天然适合自然语言 key
3. **日志消息不本地化**：`Log.i/w/e/d()` 中的消息保持中文（或英文），不参与本地化，避免日志难以搜索
4. **分阶段实施**：可先只做 SettingsView + StatusBarController（用户直接看到的 UI），错误消息可在后续迭代中处理
