# UI 多语言化 (i18n)

## Context

WhisperUtil 当前 UI 全部硬编码中文，不支持其他语言。作为面向国际用户的工具，需要支持多语言。采用 Xcode String Catalogs (.xcstrings) 方案，实现即时语言切换（无需重启）。

参考文档：`.claude-tech-research/12_ui_localization.md`

## UI 支持语言（20 种）

按全球使用人数排序，Whisper 均支持识别。语言名称用其自身语言显示：

| 显示名 | 代码 | 显示名 | 代码 |
|--------|------|--------|------|
| English | en | العربية | ar |
| 简体中文 | zh-Hans | हिन्दी | hi |
| 繁體中文 | zh-Hant | Bahasa Indonesia | id |
| 日本語 | ja | ไทย | th |
| 한국어 | ko | Tiếng Việt | vi |
| Español | es | Türkçe | tr |
| Français | fr | Polski | pl |
| Deutsch | de | Nederlands | nl |
| Português | pt | Italiano | it |
| Русский | ru | Svenska | sv |

English 为开发语言（Base / fallback）。

## 核心架构：LocaleManager

新增 `Utilities/LocaleManager.swift`，统一管理应用 locale，实现即时切换：

```swift
@MainActor
final class LocaleManager: ObservableObject {
    static let shared = LocaleManager()
    
    /// 当前生效的 Locale（SwiftUI 通过 .environment(\.locale) 注入）
    @Published var currentLocale: Locale
    
    /// 当前 locale 对应的 Bundle（AppKit 用此 Bundle 加载本地化字符串）
    @Published var currentBundle: Bundle
    
    /// 根据 locale 代码加载对应的 .lproj Bundle
    func setLocale(_ code: String) { ... }
    
    /// 供 AppKit 使用的本地化函数
    func localized(_ key: String) -> String {
        currentBundle.localizedString(forKey: key, value: nil, table: nil)
    }
    
    /// 供日志使用的本地化函数（使用 logLocale 而非 UI locale）
    func logLocalized(_ key: String) -> String {
        logBundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
```

**即时切换原理：**
- SwiftUI：根视图注入 `.environment(\.locale, localeManager.currentLocale)`，locale 变更时 SwiftUI 自动重新渲染
- AppKit（StatusBarController 等）：监听 LocaleManager 变更，手动刷新菜单文字
- 日志：使用独立的 logBundle，根据 EngineeringOptions.logLanguage 决定

## 三项新增需求

### 需求 1: 界面语言选项（即时生效）

设置面板「通用」Section 中新增 Picker，语言名用自身语言显示：

```
Interface Language:  [Follow System ▾]
                     ─────────────────
                     Follow System       ← 默认
                     English
                     简体中文
                     繁體中文
                     日本語
                     한국어
                     Español
                     Français
                     Deutsch
                     Português
                     Русский
                     العربية
                     हिन्दी
                     Bahasa Indonesia
                     ไทย
                     Tiếng Việt
                     Türkçe
                     Polski
                     Nederlands
                     Italiano
                     Svenska
```

实现：
- SettingsStore 新增 `@Published var appLanguage: String`，默认 `"system"`
- 变更时调用 `LocaleManager.shared.setLocale(code)`
- SwiftUI 自动刷新，AppKit 手动刷新菜单

### 需求 2: 识别语言「与界面语言一致」

```
Recognition Language:  [Auto Detect ▾]
                       ────────────────
                       Auto Detect              ← tag("")
                       Same as Interface         ← tag("ui")
                       ────────────────
                       English                   ← tag("en")
                       简体中文                   ← tag("zh")
                       日本語                     ← tag("ja")
                       ... (20+ 种)
```

实现：
- tag `"ui"` 在 RecordingController/Service 层映射为 LocaleManager 当前 locale 的 Whisper 代码
- 识别语言列表从 5 种扩展到 20+ 种

### 需求 3: 日志语言（与界面语言相同架构）

EngineeringOptions 新增：

```swift
/// 日志语言
/// - "en": English（默认）
/// - "zh": 中文
static let logLanguage = "en"
```

实现：
- 日志字符串放入独立的 `LogStrings.xcstrings`（仅 en + zh-Hans 两种语言）
- LocaleManager 维护独立的 `logBundle`，根据 `logLanguage` 加载 en 或 zh-Hans
- 所有 `Log.i/w/e/d()` 调用改为使用 logBundle 本地化
- 日志翻译仅 en + zh，不参与 UI 的 20 语言体系

## 实施步骤

### Step 1: 配置 Xcode 项目

修改 `project.pbxproj`：
- `developmentRegion = en`
- `knownRegions`: en, zh-Hans, zh-Hant, ja, ko, es, fr, de, pt, ru, ar, hi, id, th, vi, tr, pl, nl, it, sv, Base
- 创建 `WhisperUtil/Localizable.xcstrings` 并加入项目

### Step 2: 新增 `Utilities/LocaleManager.swift`

核心 locale 管理器（见上方架构）。提供：
- `currentLocale` / `currentBundle` — UI 用
- `logBundle` — 日志用
- `setLocale()` — 即时切换
- `localized()` — AppKit 本地化函数
- `logLocalized()` — 日志本地化函数

### Step 3: 新增 EngineeringOptions.logLanguage

在 `Config/EngineeringOptions.swift` 新增字段。

### Step 4: 修改 SettingsStore

- 新增 `@Published var appLanguage: String`（默认 `"system"`）
- 变更时调用 `LocaleManager.shared.setLocale()`

### Step 5: 修改 SettingsView.swift

- 所有中文字面值改为英文 key
- 新增「界面语言」Picker（语言名用自身语言显示）
- 识别语言 Picker 新增「Same as Interface」+ 扩展到 20+ 种
- 根视图注入 `.environment(\.locale, localeManager.currentLocale)`

### Step 6: 修改 StatusBarController.swift

- 所有 NSMenuItem title 改为 `LocaleManager.shared.localized("key")`
- 监听 LocaleManager 变更，刷新菜单文字
- AutoSendMode.displayName 同样本地化

### Step 7: 修改 SettingsWindowController.swift

窗口标题本地化 + 注入 locale environment。

### Step 8: 修改错误/通知消息

所有用户可见消息用 `String(localized:)` 或 `LocaleManager.shared.localized()` 包裹。
涉及：RecordingController、AppDelegate、AudioRecorder、ServiceLocalWhisper、ServiceCloudOpenAI、ServiceRealtimeOpenAI、ServiceTextCleanup、SettingsStore、ApiKeyValidator

### Step 9: 修改所有 Log 调用

所有 `Log.i/w/e/d()` 中的字符串改为 `LocaleManager.shared.logLocalized("key")`。
约 80+ 处日志调用。

### Step 10: 创建 Localizable.xcstrings

JSON 格式 String Catalog，包含：
- UI 字符串 ~90 个 × 20 种语言 = ~1800 翻译条目（Localizable.xcstrings）
- 日志字符串 ~80 个 × 2 种语言 = ~160 翻译条目（LogStrings.xcstrings，仅 en + zh）
- 使用 AI 辅助生成翻译

### Step 11: 实现「与界面语言一致」映射

在 RecordingController / Config 层，`"ui"` → Whisper 语言代码映射。

### Step 12: 更新文档

- `CODEBASE_INDEX.md` — 新增 LocaleManager.swift、Localizable.xcstrings 条目
- 更新 EngineeringOptions 描述

## 不需要本地化

- API endpoint URL、技术常量
- UserDefaults key 字符串
- Whisper language code（`"zh"`, `"en"` 等）

## 验证

```bash
make build  # 编译通过
make dev    # 启动
```

检查项：
1. 设置面板切换「界面语言」→ UI 即时刷新（无需重启）
2. 菜单栏菜单项同步更新语言
3. 识别语言「Same as Interface」正确映射
4. 日志语言随 EngineeringOption 变化
5. 各语言文本不截断、布局正常
6. 「Follow System」选项正确读取系统语言
