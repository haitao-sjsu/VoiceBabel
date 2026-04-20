# Fallback Transparency —— 引擎归属与静默失败

日期: 2026-04-16
类别: UX 设计思考 / 架构研究
触发: 用户观察到 "如果第一个引擎失败,第二个补上,用户根本不知道"

## 一、问题陈述

当前 WhisperUtil 在转录和翻译两个维度上都有"优先级 + 自动回退"的双引擎策略:

| 维度 | 优先级默认值 | 回退开关 |
|------|-------------|---------|
| 转录 | `["cloud", "local"]` | `EngineeringOptions.enableModeFallback` |
| 翻译 | `["apple", "cloud"]` | 同上 |

这个设计的初衷是提高可靠性 —— 一个失败,另一个补位。但它同时制造了一类新的问题:**引擎归属的不可见性**。用户有三个无法回答的问题:

1. **"我以为我在用 Cloud,实际是吗?"** —— 用户的心智模型("我选了 Cloud")和实际运行时的状态(Cloud 刚刚静默失败,Local 接管了)发生偏离,用户没有任何视觉信号可以察觉。
2. **"这次的输出是谁给的?"** —— 菜单里的 "Copy Last Transcription" 只显示文本,不显示来源。用户读不出来这句话是 Cloud 转的还是 Local 转的。
3. **"上一次的失败,发生过吗?"** —— 失败只写进 `whisperutil.log`。普通用户不会打开日志,失败成为一个"从未发生过"的事件。

用户还提到了一个很重要的未来场景:**单引擎配置**。如果用户把优先级设为 `["cloud"]`(只有一个),失败必然显式暴露 —— 因为没有人接盘。但今天的默认配置是双引擎,**回退会把本应显式的失败变成隐式的降级**。这种"降级"在运营上叫 graceful degradation,在用户体验上叫"你骗了我"。

核心问题可以浓缩成一句:**当前架构把"优先级"当成"偏好",但用户直觉上把它当成"指令"。**

## 二、当前实现状况(基线盘点)

### 2.1 转录回退(RecordingController)

- `transcribeWithFallback(priorityIndex:)` 递归尝试优先级队列
- Cloud 失败且是 networkError 时,触发 `enterFallbackMode(mode: "cloud")`:
  - 设置 `isInFallbackMode = true`
  - **触发一次 `onError?("Switched to fallback transcription mode")`** —— 这是唯一的用户可见信号,但它走的是错误弹窗通道,3 秒后消失(`errorRecoveryDelay`)
  - 更新 `currentApiMode` 为下一个引擎
- 非 networkError(比如 API Key 401)不触发回退,直接报错 —— 正确
- Local 失败时只调用 `transcribeWithFallback(priorityIndex: n+1)`,**没有触发 enterFallbackMode 的等价信号**

### 2.2 翻译回退(TranslationPipeline)

- `translateTextWithFallback(engineIndex:)` 递归尝试
- Apple 失败 → 尝试 Cloud:**只有 `Log.w` 一行日志,对用户完全无感知**
- Cloud 失败 → 尝试 Apple:同上
- 没有 `isInFallbackMode` 等价物,没有任何用户信号

这是两个子系统的**不对称** —— 转录的回退至少闪了一下错误弹窗,翻译的回退完全静默。从用户视角看,翻译这条路径是纯黑盒。

### 2.3 UI 侧的现状(StatusBarController)

- 菜单栏图标:`🎙📶` (cloud) / `🎙🏠` (local),**反映的是 `currentApiMode` 这个"偏好变量",不是实际引擎**
- `fallback` 状态下 `currentApiMode` 会被更新 —— 所以图标其实会跟着变 —— 但:
  - 变化发生在 fallback 触发的那一刻,持续时间不明确
  - 图标没有"degraded" 的视觉提示,用户看到 `🎙🏠` 时无法区分"我主动选了 Local" vs "Cloud 挂了自动降到 Local"
- `showNotification` **是个 stub**(只有 `Log.i`,没有调用 `UNUserNotificationCenter`)
- 菜单项 "Copy & Paste Last Transcription" 只显示文本预览,**不带引擎归属**
- 翻译路径:根本没有触及 `StatusBarController`,因为 `TranslationPipeline` 没有 fallback 的 UI 通知

### 2.4 Services 层审计(07_services_fallback_audit.md)的启示

那份 audit 关注的是**语言的**静默回退("空 language 被硬编码为 en")。本次研究关注的是**引擎的**静默回退,但本质是同一类 bug:

> "某处发生了决定性的状态切换,用户不知道,日志里有一行,但不在任何用户会看到的地方。"

Services 审计里的 fix 方向("把回退信号放大,让它变成 Log.w 或显式 Error,而不是悄悄 return 一个假值")对引擎归属问题同样适用 —— 只是信号的受众从日志读者变成了菜单栏用户。

## 三、设计哲学:输出带血统(Provenance)

这是本次思考的核心观点。

当前系统的输出是一个 `String`,它跟文本本身一起走完整条管道。但这个 String **应该携带元数据**:

```swift
struct TranscriptionOutput {
    let text: String
    let engine: EngineID            // "cloud" / "local"
    let fallbackFromEngine: EngineID?  // 如果这是 fallback 的结果
    let duration: TimeInterval
}
```

这个改动本身是架构上的,不需要立刻实施 —— 但它是后续一切 UI 改进的基础。没有 provenance,任何"让用户知道引擎"的 UI 都是基于猜测的(比如"当前 currentApiMode 是什么"这种 presumption),而不是基于事实。

**原则:用户看到的每一次输出,都应该能回答"这是谁给的",不是通过猜测全局状态,而是通过读取那次输出自带的元数据。**

## 四、设计选项(并不互斥)

### 选项 A:菜单项带引擎归属标签

最小改动。把 "Copy Last Transcription" 的菜单项改成:

```
Copy & Paste Last Transcription:
  ☁️ 📋 Hello world...          (Cloud, 2.1s)
Copy & Paste Last Translation:
  🍎 📋 Bonjour tout le monde...  (Apple Translation, 0.3s)
```

- **成本**:低。只需要 `TranscriptionOutput` 的 provenance(或者就近的 "上一次实际调用了哪个引擎" 变量)+ 菜单字符串调整。
- **可见性**:中。用户需要打开菜单才能看到。
- **价值**:即便没有任何其他改动,这一条足以回答"这次的输出是谁给的"。

### 选项 B:菜单栏图标反映"实际引擎" + 降级标记

当前图标是 `currentApiMode` 的投影。把它改成"上次成功输出的引擎"的投影,并且**在 fallback 状态下加一个视觉角标**:

```
正常 Cloud:  🎙📶
正常 Local:  🎙🏠
Fallback 到 Local:  🎙🏠⚠️ 或 📶→🏠
```

- **成本**:中。需要区分"用户偏好"和"实际状态",`setApiMode` 和 fallback 路径都要分别处理。
- **可见性**:高。菜单栏始终可见。
- **风险**:emoji 组合拼贴可能难看;国际化和无障碍不友好。可考虑换成 NSImage + SF Symbol。

### 选项 C:系统通知(macOS UserNotifications)

当 fallback 触发时,弹一条系统通知:

> "Cloud transcription failed — using Local Whisper instead"
> "Apple Translation unavailable — using Cloud GPT instead"

- **成本**:中。需要权限请求、替换 `showNotification` stub、去抖动(避免 10 次失败弹 10 条)。
- **可见性**:最高。难以错过。
- **风险**:打扰用户。必须有 Settings 里的 opt-out 开关。建议默认**仅在"fallback 模式首次进入"时通知一次**,同一会话内不重复。

### 选项 D:菜单顶部的"引擎状态摘要"区

在 "Start Transcription" 之上加一行不可点击的状态说明:

```
⚠️ Fallback active — Cloud unavailable, using Local
────────────────────
🎤 Start Transcription (⌥)
🌐 Start Translation (⌥⌥)
```

仅在 `isInFallbackMode == true` 时显示。

- **成本**:低。菜单构造多一个 NSMenuItem,按状态切换 `isHidden`。
- **可见性**:中高(用户打开菜单时立即看到)。
- **价值**:把"降级"这件事做成一个持续的、非骚扰的状态显示,而不是一次性弹窗。

### 选项 E:取消"自动回退默认开启" —— 让用户在 Settings 显式选择

把 `EngineeringOptions.enableModeFallback` 从工程选项升级为用户选项,**默认改为关闭**,或者至少把"回退"分成两级策略:

- `never` —— 失败就报错(今天单引擎场景的行为)
- `notify` —— 回退 + 强通知(默认推荐)
- `silent` —— 回退 + 仅日志(重度用户)

- **成本**:中。引入一个设置项、UI、迁移逻辑。
- **哲学意义**:把"我要不要被骗"的决定权交还给用户。这是最正的长期方向。
- **风险**:增加配置复杂度;对"只想用,不想配"的用户是负担。

## 五、建议的分层方案(按影响 / 成本比排序)

基于 CLAUDE.md 里的三条原则(**log 要多**、**defensive but not paranoid**、**不要过度工程**),我的建议顺序是:

### 第一层 —— 低成本、覆盖 80% 痛点(本周可做)

1. **选项 A:菜单项带引擎归属**
   - 在 `RecordingController` / `TranslationPipeline` 输出回调里附加 `engine` 参数(不做完整 Provenance struct,直接 `onTranscriptionResult: (String, engine: String)`)
   - `StatusBarController.setLastTranscription(_:engine:)` 根据引擎选择图标
2. **选项 D:fallback 状态条**
   - `StatusBarController` 暴露 `setFallbackState(active: Bool, reason: String?)`
   - `RecordingController.enterFallbackMode` 调用它;`recoverFromFallback` 清除它
   - 同样在 `TranslationPipeline` 里补上等价调用(今天翻译路径完全静默,必须补)

这两项合起来可以回答用户提的三个问题的前两个("现在是谁" / "刚才是谁"),而且完全不打扰用户。

### 第二层 —— 中成本、解决"失败了我不知道"(下一轮)

3. **选项 C:系统通知(仅在 fallback 首次触发时)**
   - 替换掉 `StatusBarController.showNotification` 的 stub,接 `UNUserNotificationCenter`
   - 触发策略:**每个会话、每个维度(转录/翻译)只通知一次进入 fallback,一次退出 fallback**。避免连续失败洗屏
   - 加 Settings 开关"Show fallback notifications"(默认 on)

### 第三层 —— 长期架构(按需)

4. **Provenance struct**:把回调统一成 `TranscriptionOutput` / `TranslationOutput`,把 engine / duration / fallbackChain 都装进去。`.claude-code-review/` 或未来的 devlog 里会有人感谢这件事。
5. **选项 E 的三级回退策略**:等到有用户真的抱怨"我不想被自动降级"再做。今天没数据支持必要性。

## 六、单引擎场景的特殊考虑

用户提到"未来用户可能只指定一个引擎"。这个场景下:

- `transcriptionPriority = ["cloud"]` 时,`transcribeWithFallback` 在 `priorityIndex = 1` 处直接走 `guard priorityIndex < priority.count` 分支,触发 `handleError("All transcription modes failed")` —— **今天的行为已经是正确的:显式失败,弹错误。**
- 翻译路径同理。

所以"单引擎不会被静默吃掉"这件事,架构上今天就成立。**本次研究的所有建议,都只解决"多引擎"场景下的归属问题。单引擎路径不需要改。**

有一个边角情况值得记下来:如果用户从"双引擎 + fallback"配置**切换**到"单引擎",今天的 `isInFallbackMode` 可能还是 true(残留状态)。需要在 `userDidChangeApiMode` / 翻译优先级变更里清除它 —— 现在只有 API mode 变化时清除了,翻译优先级变化时没有。这是个潜在 bug,属于第二层工作顺带修。

## 七、开放问题(下次讨论)

1. **"fallback 成功" 是不是也该通知?** 今天只通知"降级发生了",但当网络恢复、主引擎回来时,用户可能也想知道。现有的 `recoverFromFallback()` 被 `NetworkHealthMonitor` 调用,但没有发出任何 UI 信号。
2. **引擎的"实时"状态 vs "最近一次"状态 —— UI 应该反映哪个?** 图标反映"即将用"更符合用户意图("我现在录,会走哪条路?"),但菜单项反映"刚刚用的"更诚实("上一句是谁转的")。两者可以并存。
3. **翻译引擎顺序 apple → cloud 的合理性:** Apple Translation 需要语言包预下载,未安装时会失败。用户看到"总是走 Cloud"可能会怀疑 Apple 没生效。是不是应该在 Settings 里明确说明"Apple Translation 需要预先在系统设置里下载语言包"?(参见 Services audit Finding #5 —— 那里提过用 `packNotInstalled` 区分错误的想法)
4. **多次连续失败的处理:** 如果 Cloud 在一个会话内失败 5 次,是不是应该"粘"在 Local 不再尝试 Cloud?今天 `cloudProbeInterval = 30s` 的 probe 会持续尝试回到 Cloud。粘性策略值得做 A/B。

## 八、总结

用户直觉是对的 —— 静默降级是个有意为之的工程决策,但它破坏了"用户看到什么 = 系统在做什么"的对应关系。修复不需要大动架构,只需要**让每一次输出都带血统,让每一次降级都留痕迹**。具体落地按成本排序:

1. 菜单项带引擎标记(今天)
2. Fallback 状态条(今天)
3. 系统通知 + 开关(下一轮)
4. Provenance 数据结构(需要时)

这些改动全都符合 CLAUDE.md 第一条原则("Log generously")的精神扩展 —— 区别只是把**日志**搬到了**菜单栏**,因为用户不读日志,但看得见菜单栏。
