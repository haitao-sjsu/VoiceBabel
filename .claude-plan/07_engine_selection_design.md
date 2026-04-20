# 引擎可选性设计:主观 × 客观

## 0. 范围说明

**在范围内**:
- **主观维度**:用户明确不想用某引擎(例如隐私偏好,不想把音频上云)
- **客观永久维度**:系统层面永久不可用(macOS 版本太旧没有 Apple Translation、未配置 API Key、WhisperKit 模型未下载)

**暂不考虑**(用户明确排除):
- 客观临时维度:网络瞬时抖动、API 限流、WhisperKit 加载中等。这部分现有 `TranscriptionManager` / `TranslationManager` 的 call-time fallback 已经覆盖,本次不动。

---

## 1. 当前架构梳理

现有代码已经实现了"优先级有序数组 + 运行时 fallback"这一层:

| 组件 | 现状 |
|------|------|
| `SettingsStore.transcriptionPriority: [String]` | 已有,`@Published`,持久化 UserDefaults |
| `SettingsStore.translationEnginePriority: [String]` | 已有,同上 |
| `UI/SettingsView.swift` 的 `PriorityList` 组件 | 已有拖拽排序,每行带 "Primary" 徽章 |
| `TranscriptionManager.tryEngine(at:)` | 已实现按 priority 顺序尝试 + fallback |
| `TranslationManager.translateTextWithFallback` | 同上 |

**但目前缺两块**:

1. **主观启用/禁用**:优先级数组里出现的引擎会全部尝试,用户无法说"永远别用 Cloud"。优先级 ≠ 启用。
2. **客观可用性的统一表达**:`isReady()` / `#available(macOS 15.0)` / `hasApiKey` / `canImport(Translation)` 散落在服务与管线的调用点,**UI 对"为什么不能用"完全无感**——用户打开设置看到两个引擎并排,但可能其中一个实际根本无法使用。

---

## 2. 核心概念:两层可用性模型

任何引擎在某时刻,对用户而言处于下面四个象限之一:

|              | 客观可用 | 客观不可用 |
|--------------|---------|-----------|
| **主观启用** | ✅ 生效(会被尝试) | ⚠️ 客观阻断(UI 灰显 + 原因) |
| **主观禁用** | ⏸️ 用户主动关闭 | ⛔ 双重不可用(UI 灰显 + 原因 + 关闭) |

**核心公式**:
```
effectiveEngineList = priority
    .filter { userEnabled[engine]  }   // 主观过滤
    .filter { objectivelyUsable(engine) }   // 客观过滤
```

`TranscriptionManager` / `TranslationManager` 收到的永远是这个经过两层过滤后的列表。它们内部的 call-time fallback 逻辑不变,只是输入源变得更干净。

---

## 3. 数据模型:三种选型

### 选型 A:两个独立字段(priority + enabled Set)

```swift
@Published var transcriptionPriority: [String]         // 现有
@Published var enabledTranscriptionEngines: Set<String> // 新增
```

- **优点**:改动最小,与现有代码完全兼容
- **缺点**:两份数据需同步(新增引擎时两边都得记得加);UI 需要分别渲染两个概念

### 选型 B:合并为 `[(String, Bool)]` / 结构体数组

```swift
struct EnginePref: Codable {
    let id: String
    var enabled: Bool
}
@Published var transcriptionEnginePrefs: [EnginePref]
```

- **优点**:单一数据源,顺序与启用状态强绑定,序列化语义清晰
- **缺点**:UserDefaults 存 Codable 略比 `[String]` 重;与现有 `[String]` 数组风格不一致,需要迁移旧字段

### 选型 C(推荐):沿用 `[String]` 数组 + 并行 `[String: Bool]` 字典

```swift
@Published var transcriptionPriority: [String]                // 现有,不动
@Published var transcriptionEnabled: [String: Bool]           // 新增
```

- **优点**:
  - 不破坏现有代码,`transcriptionPriority` 的读者(Combine 订阅、Manager)继续按原逻辑工作
  - 字典的 key 即 engine id,新增引擎自动补默认 `true`(缺失即视为启用)
  - UserDefaults 直接支持 `[String: Bool]`
- **缺点**:两个字段,理论上可以不同步(某个 id 在 priority 里但字典没有对应 key)——通过在 `SettingsStore.init` 里做一次"补齐"即可

**推荐 C**。最小破坏性改动,最清晰的概念分离(顺序 / 启用各管一件事)。

---

## 4. 客观可用性的抽象

### 4.1 类型定义

新建 `Config/EngineAvailability.swift`:

```swift
enum EngineID: String, CaseIterable {
    // Transcription
    case cloudTranscribe = "cloud"
    case localWhisper    = "local"
    // Translation
    case appleTranslation = "apple"
    case cloudTranslation = "cloud-translation"  // 见注释 *
}

enum EngineAvailability: Equatable {
    case available
    case unavailable(UnavailabilityReason)
}

enum UnavailabilityReason: Equatable {
    case missingApiKey                       // 未配置 OpenAI API Key
    case osTooOld(requiredVersion: String)   // 例如 "macOS 15.0"
    case frameworkUnavailable                // canImport(Translation) 失败
    case localModelNotLoaded                 // WhisperKit 模型未 ready
}
```

**注释 \***:当前代码里 transcription 和 translation 都用 `"cloud"` 作 id,不冲突因为分属不同数组。但用一个统一的 `EngineID` enum 更清晰。两种方案:
- 保持 id 字符串分命名空间(例如 `"cloud"` 在 transcription 里、`"cloud"` 在 translation 里,靠上下文区分)——兼容现有代码
- 用不同 id(例如 `cloudTranscribe` / `cloudTranslation`)——更明确但要改现有字符串

**推荐**:保持现有字符串命名不变(transcription 用 `"cloud"`/`"local"`,translation 用 `"apple"`/`"cloud"`),`EngineID` 只用于类型安全的新代码;两者之间通过一个 mapping 函数转换。避免动现有 UserDefaults 值的迁移问题。

### 4.2 可用性探测函数

自由函数,而非服务方法(低耦合,服务单一职责保持干净):

```swift
// EngineAvailability.swift
struct EngineAvailabilityProbe {
    let settingsStore: SettingsStore           // 读 hasApiKey
    let localWhisperService: LocalWhisperService  // 读 isReady()

    func availability(ofTranscriptionEngine id: String) -> EngineAvailability {
        switch id {
        case "cloud":
            return settingsStore.hasApiKey ? .available : .unavailable(.missingApiKey)
        case "local":
            return localWhisperService.isReady() ? .available : .unavailable(.localModelNotLoaded)
        default:
            return .unavailable(.frameworkUnavailable)
        }
    }

    func availability(ofTranslationEngine id: String) -> EngineAvailability {
        switch id {
        case "apple":
            #if canImport(Translation)
            if #available(macOS 15.0, *) { return .available }
            return .unavailable(.osTooOld(requiredVersion: "macOS 15.0"))
            #else
            return .unavailable(.frameworkUnavailable)
            #endif
        case "cloud":
            return settingsStore.hasApiKey ? .available : .unavailable(.missingApiKey)
        default:
            return .unavailable(.frameworkUnavailable)
        }
    }
}
```

**重要设计决定**:客观可用性**不缓存、不持久化**——它本质是"此时此刻"的系统状态,每次查询即时算。持久化只对"主观启用"做。

### 4.3 变更通知

客观可用性可能在运行时变化(用户新配了 API Key、下载了 WhisperKit 模型、升级了系统)。我们需要 UI 和 Manager 感知:

- **API Key 变化**:`SettingsStore.apiKeyVersion` 已有,沿用
- **WhisperKit 模型就绪**:目前 `localWhisperService.isReady()` 是纯查询,没有变更通知。**方案**:给 `LocalWhisperService` 加一个 `@Published var isReadyState: Bool`,在加载/卸载模型时更新
- **macOS 版本** / **framework 可用性**:进程生命周期内不可变,不用监听

AppDelegate 里合并订阅(`Publishers.CombineLatest`):

```swift
Publishers.CombineLatest4(
    settingsStore.$transcriptionPriority,
    settingsStore.$transcriptionEnabled,
    settingsStore.$apiKeyVersion,
    localWhisperService.$isReadyState
)
.sink { [weak self] priority, enabled, _, _ in
    self?.recomputeAndPushEngineList(.transcription)
}
```

---

## 5. 后端改造清单

### 5.1 新增 / 修改的文件

| 文件 | 动作 | 说明 |
|------|------|------|
| `Config/EngineAvailability.swift` | **新增** | `EngineAvailability` / `UnavailabilityReason` 类型 + `EngineAvailabilityProbe` |
| `Config/SettingsStore.swift` | **修改** | 新增 `transcriptionEnabled: [String: Bool]`、`translationEngineEnabled: [String: Bool]`,`init` 补齐缺失 key |
| `Config/SettingsDefaults.swift` | **修改** | 新增默认启用映射(所有引擎默认 `true`) |
| `Services/LocalWhisperService.swift` | **修改** | 加 `@Published var isReadyState: Bool` |
| `Core/AppController.swift`(或 `AppDelegate.swift`) | **修改** | 新增 `recomputeAndPushEngineList` 合并订阅,把有效列表推给 Manager |
| `Core/TranscriptionManager.swift` | **修改(小)** | 接收的 `priority` 现在是"已过滤"的结果;保留内部的 call-time fallback |
| `Core/TranslationManager.swift` | **修改(小)** | 同上 |
| `UI/SettingsView.swift` | **修改** | `PriorityList` 改造(见 §6) |

### 5.2 "无可用引擎"的运行时错误

当用户按下录音键,`recomputeAndPushEngineList` 得出的有效列表为空:

- **不应静默失败或 fallback 到默认值**(违反 CLAUDE.md "loud failure" 原则)
- `TranscriptionManager.transcribe()` / `TranslationManager.translate()` 第一行判断 `priority.isEmpty`,直接 `onError` 报出一个专门的本地化字符串:`"No transcription engine is available. Check Settings."`
- 同时 `Log.e` 打出完整上下文(用户启用集合、客观可用性字典)

### 5.3 现有 `EngineeringOptions.enableModeFallback` 不动

它控制的是"call-time 失败后要不要试下一个",与本次"预先过滤"正交。保留。

---

## 6. UI 设计

### 6.1 新的一行布局

```
┌────────────────────────────────────────────────┐
│ [Toggle]  ☁️  Cloud API                [Primary] │
│                gpt-4o-transcribe, needs network  │
└────────────────────────────────────────────────┘
```

当**客观不可用**时:

```
┌────────────────────────────────────────────────┐
│ [Toggle 灰显]  🍎  Apple Translation   [Unavail] │
│                Requires macOS 15.0 or later      │
└────────────────────────────────────────────────┘
```

当**主观禁用**(客观可用):整行半透明,Toggle 在 off。

### 6.2 `PriorityList` 改造

核心改动(在现有 `UI/SettingsView.swift` 的 `PriorityList` 基础上):

```swift
private struct PriorityList: View {
    @Binding var items: [String]
    @Binding var enabled: [String: Bool]             // 新增
    let availability: (String) -> EngineAvailability // 新增,由外部注入
    let icon: (String) -> String
    let name: (String) -> LocalizedStringKey
    let description: (String) -> LocalizedStringKey

    var body: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                Row(
                    item: item,
                    index: index,
                    isEnabled: Binding(
                        get: { enabled[item] ?? true },
                        set: { enabled[item] = $0 }
                    ),
                    availability: availability(item),
                    icon: icon(item),
                    name: name(item),
                    description: description(item)
                )
            }
            .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }
        }
    }
}

private struct Row: View {
    let item: String
    let index: Int
    @Binding var isEnabled: Bool
    let availability: EngineAvailability
    // ...

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .disabled(availability != .available)  // 客观不可用 = 禁用开关

            Image(systemName: icon).foregroundColor(.accentColor).frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundColor(subtitleColor)
            }

            Spacer()

            if isEffectivelyActive && index == firstActiveIndex {
                Badge(text: "Primary", color: .green)
            } else if !isEnabled {
                Badge(text: "Disabled", color: .secondary)
            } else if availability != .available {
                Badge(text: "Unavailable", color: .orange)
            }
        }
        .opacity(isEnabled ? 1.0 : 0.55)
    }

    private var subtitleText: LocalizedStringKey {
        switch availability {
        case .available: return description
        case .unavailable(.missingApiKey):   return "API Key required"
        case .unavailable(.osTooOld(let v)): return "Requires \(v) or later"
        case .unavailable(.frameworkUnavailable): return "Not supported on this system"
        case .unavailable(.localModelNotLoaded):  return "Local model not ready"
        }
    }
}
```

### 6.3 "Primary" 徽章的含义变化

之前:数组索引 0 固定是 Primary。
现在:Primary 是**有效列表的第 0 项**(已过滤主观禁用和客观不可用后)。如果用户把 Cloud 拖到第一但关掉它,Primary 显示在 Local 那一行。

### 6.4 全部禁用的警告

Section footer 检测到有效列表为空时,改成红字警示:

```
⚠️ No transcription engine enabled. Transcription will fail.
```

### 6.5 现有"Output Language"等无关字段原位保留

只改 Transcription Section 和 Translation Engine Priority Section 两处。

---

## 7. 典型场景走查

### 场景 A:macOS 14 用户

- Apple Translation 行:Toggle 灰显、Unavailable 徽章、副标题 "Requires macOS 15.0 or later"
- Cloud 行:正常
- 用户即便把 Apple 拖到首位,实际还是走 Cloud(因为客观过滤剔除 Apple)
- 升级到 macOS 15 后,Apple 行自动激活,不需要用户操作设置

### 场景 B:未配置 API Key

- Cloud Transcription 行 + Cloud Translation 行:Unavailable,副标题 "API Key required"
- Local Transcription 和 Apple Translation 正常
- 用户走 Local + Apple 流程
- 配置 Key 后(`apiKeyVersion` 变化触发订阅),两行自动激活

### 场景 C:用户关闭 Cloud 追求隐私

- Cloud 行:Toggle off、Disabled 徽章、整行半透明
- 优先级里仍然可见 Cloud,但不参与调度
- 用户即便断网,Local 也不会尝试 fallback 到 Cloud(因为主观过滤已剔除)

### 场景 D:用户全部禁用

- Transcription Section footer 红字警示
- 用户按下录音键:onError 立刻弹出 "No transcription engine available. Check Settings."
- Log.e 打印完整状态

---

## 8. 分阶段实施

### Phase 1:数据模型与可用性探测(可独立验证)

**改动**:
- 新建 `Config/EngineAvailability.swift`
- `SettingsStore` 新增 `transcriptionEnabled` / `translationEngineEnabled` 字典字段(含 init 补齐)
- `SettingsDefaults` 新增默认启用映射
- `LocalWhisperService` 新增 `@Published isReadyState`

**验证**:
- 单元测试(或手动 Log)验证:切换 API Key / 切换 WhisperKit 就绪状态,`EngineAvailabilityProbe.availability(of:)` 返回正确
- 修改 UserDefaults 中的字典 key,重启后正确加载

### Phase 2:AppController 合并订阅 + Manager 过滤后输入(可独立验证)

**改动**:
- `AppController` / `AppDelegate` 新增 `recomputeAndPushEngineList` 逻辑,Combine 合并订阅四个源
- 把有效列表推给 `TranscriptionManager.priority` / `TranslationManager.translationEnginePriority`
- 两个 Manager 的 `transcribe()` / `translate()` 首行判断 `priority.isEmpty` → `onError`

**验证**:
- 手动在代码里把某引擎的 enabled 设为 false,录音不会走它
- 全部禁用,录音立刻报错(不是 fallback 耗尽后才报)

### Phase 3:UI 改造(可独立验证)

**改动**:
- `UI/SettingsView.swift` 的 `PriorityList` 增加 `enabled` 绑定和 `availability` 闭包
- 新增 `Row` 子视图,实现徽章、副标题、禁用态
- Section footer 增加"全部禁用"红字警示
- `SettingsView` 注入外部的 `EngineAvailabilityProbe` 引用

**验证**:
- 在 macOS 14 机器(或 `#if` 模拟)上看 Apple Translation 行的灰显
- 清空 API Key,看两个 Cloud 行的灰显
- 关闭某引擎,看 Primary 徽章跳到下一行
- 关闭全部,看红字警示

### Phase 4:i18n 与文案打磨

**改动**:
- `WhisperUtil/Localizable.xcstrings` 新增:
  - "API Key required"
  - "Requires {version} or later"
  - "Not supported on this system"
  - "Local model not ready"
  - "No transcription engine enabled. Transcription will fail."
  - "No transcription engine available. Check Settings."
  - "Disabled" / "Unavailable" / "Primary" 徽章
- `WhisperUtil/LogStrings.xcstrings` 增加相应 log key

**验证**:
- 切换中英文,所有副标题和徽章正确显示

---

## 9. 边界情况与开放问题

### 9.1 设计决定(我已取态)

1. **客观不可用的引擎是否从设置 UI 中隐藏?** — **不隐藏,灰显 + 原因**。讓用户知道"还有这个选项,满足 XX 条件就能用",提升可发现性。
2. **客观可用性是否缓存?** — **不缓存**,每次实时查询。可用性依赖的四个信号(API Key、模型就绪、macOS 版本、framework 可用)都很便宜,不需要缓存。
3. **API Key 已配但网络暂时坏**:主观启用 + 客观可用 → 进入有效列表 → call-time 失败后走现有 Manager 的 fallback 逻辑。**本次不动这部分**。
4. **徽章色彩**:Primary 绿,Disabled 灰,Unavailable 橙。避免用红色做常态,红色仅留给"全部禁用"这种真实错误状态。

### 9.2 留给用户确认

1. **默认启用策略**:新装时所有引擎都默认 `true`(推荐)。升级场景下 UserDefaults 里没有 `transcriptionEnabled` key,`init` 补齐为全 `true`——等同于"不改变现有行为"。确认可否。
2. **UI 上 Toggle 的位置**:放在每行最左(本方案)vs 最右。最左突出"这是开关优先"的语义,最右接近现有 macOS 系统设置风格。倾向最左,但可切换。
3. **"Cloud" id 的命名**:`transcriptionPriority` 和 `translationEnginePriority` 当前都用 `"cloud"` 作 id,`transcriptionEnabled["cloud"]` 和 `translationEngineEnabled["cloud"]` 是不同字典的不同 key,**不冲突**。但如果哪天合并成单一字典就会撞车。建议现在先不动,记住这个隐患。

### 9.3 后续工作(不在本次范围)

- **临时不可用**(用户明确暂不考虑):可在 `EngineAvailability` 枚举增加 `.temporarilyUnavailable(...)`,UI 加一个 "Retry" 按钮或周期自愈。`NetworkHealthMonitor` 已经提供了网络层信号。
- **"引导配置" affordance**:Cloud 行副标题显示 "API Key required" 时,点击行跳到 API Key Section——减少用户自己去找的摩擦。
- **Engine 级用量统计**:为了后续商业化决策,记录每个引擎的使用次数和成功率,可与 `.claude-commercial-research` 的 telemetry 方案合并设计。

---

## 10. 与现有代码的兼容性要点

- **不破坏现有 UserDefaults 数据**:`transcriptionPriority` / `translationEnginePriority` 字段不改,仅**新增**两个 `*Enabled` 字典。老用户升级后,新字典为空 → init 补齐为全 `true` → 行为等同于升级前。
- **不破坏现有 Manager 接口**:Manager 还是接收 `priority: [String]`,只不过现在是"已过滤"的结果。Manager 内部对 `priority.isEmpty` 的新增判断是防御性的,对非空列表行为不变。
- **不破坏现有 `EngineeringOptions.enableModeFallback`**:其语义保持"call-time 失败后是否尝试列表里的下一个",与预过滤正交。
- **现有 `NetworkHealthMonitor` + `recoverFromFallback()` 不动**:它们处理的是 call-time fallback 后的恢复,与本次的预过滤正交。

---

## 11. 一句话总结

在已有的"有序优先级 + 运行时 fallback"上,**加一层主观启用字典**(`[String: Bool]`)和**一个客观可用性探测函数**,AppDelegate 合并订阅后把"两层过滤后的有效列表"推给 Manager,UI 在原有的拖拽行基础上加一个 Toggle 和一个说明副标题。现有代码不重写,只是在入口处多一次过滤和一个更丰富的 UI 描述。
