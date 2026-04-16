# RecordingController 转录逻辑重构分析

> 调研日期：2026-04-16
> 背景：`TranslationPipeline` 已从 `RecordingController` 拆出。用户直觉是：转录部分（cloud/local 两个 engine，音频→文本）和翻译部分（apple/cloud 两个 engine，文本→文本）结构对称，似乎也值得拆成独立 pipeline。本文回答"该不该拆，拆到什么程度，有哪些坑"。

---

## 1. 现状盘点

### 1.1 RecordingController.swift（~653 行）职责切片

| 职责 | 行数范围 | 是否可独立 |
|------|---------|----------|
| 状态机 `AppState` | 24–30, 57–61 | 否，控制器本身 |
| 录制生命周期（begin/stop/cancel/toggle） | 145–198, 202–271 | 否 |
| 音频校验（silence / RMS / 最小数据量） | 289–316, 483–507 | 否，强耦合 AudioRecorder |
| **转录编排（priority + fallback）** | 318–466, 520–562 | **是，候选** |
| 翻译编排 | 468–481 | 已拆（TranslationPipeline） |
| 错误恢复 + 3s 自动回 idle | 586–595 | 否 |
| AutoSend、播放音效、文本输出 | 628–650 | 否 |

可以看到，**转录编排大约占了 200 行**——拆掉后 RecordingController 会从 ~650 行缩到 ~450 行，"调度器"这个定位才名副其实。

### 1.2 当前的两条转录路径（关键发现）

项目里**其实已经有两处转录代码**，不止 RecordingController 这一处：

| 位置 | 特性 | fallback | 超时 |
|------|------|---------|------|
| `RecordingController.transcribeWithFallback` | 完整的 priority queue + 网络错误识别 + `enterFallbackMode` 副作用 | ✅ | ✅（local 按音频长度算） |
| `TranslationPipeline.translate`（Step 1） | 简单的 `if useLocalTranscription && isReady` 二分支 | ❌ | ❌ |

**这是强烈的重复信号**。翻译流程的第一步也是"一段音频 → 文字"，却重新写了一套更弱的实现，既没 fallback 也没超时。如果日后用户抱怨"翻译模式下网络偶尔抖一下就直接失败、而转录模式能 fallback"，根因就在这里。

### 1.3 结构对称性 vs 关键差异

用户的直觉是对的——两者确实很像，但**也有三处关键的不对称**，决定了拆出来后设计会长什么样：

| 维度 | TranslationPipeline | 转录（候选） |
|------|--------------------| ------------|
| 输入 | 单一 `String` | **双形态**：`recording.data`（cloud 要）+ `samples: [Float]`（local 要） |
| 输出 | `String` | `String` |
| Engine 列表 | apple / cloud | cloud / local |
| 准备状态检查 | Apple 版本守卫 | `localWhisperService.isReady()` |
| 超时 | 无 | **有**（仅 local，`audioDuration * 10` 夹在 min/max） |
| 副作用 | 基本无 | **`enterFallbackMode` 会改 controller 的 `currentApiMode` 与 `isInFallbackMode`** |
| 失败语义 | 单条失败路径 | cloud 只在 `.networkError` 时 fallback，其他错误直接上报 |

**双输入形态**和**副作用回写控制器状态**是最需要设计决策的两个点。

---

## 2. 推荐方案：拆，但动机不是"对称"

### 2.1 核心论点

拆的首要理由**不是**它像 TranslationPipeline，而是：

> **拆出 `TranscriptionPipeline` 能把项目里两处转录代码合并成一处**。

对称性是副作用，消除重复才是主因。这两个理由放一起，拆的 ROI 明显正向。

### 2.2 建议的边界

新文件 `Core/TranscriptionPipeline.swift` 吃下：

- `transcribeWithFallback` / `localTranscribeWithFallback` / `localTranscribeWithTimeout`
- priority queue 的迭代与 `enableModeFallback` 开关判断
- 网络错误识别（`CloudOpenAIService.WhisperError.networkError` 判定）
- local 的超时计算与 `Task` + `withThrowingTaskGroup` 骨架

**不拆进来**：

- 音频校验（`stopAndValidateRecording`）——它依赖 AudioRecorder 当前状态、依赖 `currentState = .idle` 回写，强耦合状态机，留在 RecordingController。
- `enterFallbackMode` 的状态回写——通过 **`onFallbackEntered: (String) -> Void`** 回调反馈给 RecordingController，由后者改自己的 `isInFallbackMode` / `currentApiMode`。Pipeline 保持无状态（只有配置，没有运行时状态）。
- Apple Translation 的 type-erased 成员——它只服务翻译，不进 TranscriptionPipeline。

### 2.3 接口草案

```swift
class TranscriptionPipeline {
    // 依赖
    var cloudOpenAIService: CloudOpenAIService
    let localWhisperService: LocalWhisperService

    // 配置
    var priority: [String] = SettingsDefaults.transcriptionPriority

    // 回调
    var onResult: ((String) -> Void)?           // 成功返回文本
    var onError: ((String) -> Void)?            // 所有 engine 都失败
    var onFallbackEntered: ((String) -> Void)?  // 某个 engine 因可恢复错误让出，通知上层更新 UI 状态

    func transcribe(
        recording: AudioRecorder.RecordingResult?,  // cloud 需要；纯本地场景可以为 nil
        samples: [Float],                           // local 需要；cloud-only 场景可以为空
        audioDuration: TimeInterval
    )
}
```

双输入形态的丑陋没法靠"美化参数"消除——它是物理事实（cloud API 吃编码后的 data，WhisperKit 吃解码后的 float 样本）。把它暴露成两个参数比包成一个 `enum TranscriptionInput` 更直白。

### 2.4 TranslationPipeline 的联动改造

这是整个重构的第二个 action item，不能漏。

`TranslationPipeline.translate` 当前的 Step 1（第 73–100 行）应改造成：

```swift
transcriptionPipeline.onResult = { [weak self] text in
    self?.translateStep2(transcribedText: text, targetLanguage: targetLang)
}
transcriptionPipeline.onError = { [weak self] msg in
    self?.onError?(msg)
}
transcriptionPipeline.transcribe(recording: recording, samples: samples, audioDuration: audioDuration)
```

好处：

1. 翻译模式自动获得 fallback 与超时能力
2. 转录逻辑的改进只需要改一处
3. `TranslationPipeline` 回归到"纯文本翻译 step 2"的窄职责

**需要警惕的副作用**：翻译模式现在会多出 fallback 行为。这可能改变用户预期——比如用户明确选了 cloud，转录步骤网络抖动后翻译可能用 local 转录结果跑翻译，语种/质量对齐会不一样。建议把 `onFallbackEntered` 也接进 TranslationPipeline 并写日志，让这个切换可观测。

---

## 3. 反对拆的声音（诚实列一下）

1. **增加了一个文件和一次跳转**。RecordingController 读起来不再自洽，调试链路多一跳。
2. **双输入形态不优雅**，TranscriptionPipeline 的接口比 TranslationPipeline 丑。
3. **`onFallbackEntered` 回调引入一层协作**，如果只有 RecordingController 一个消费者，"回调 + 回写状态"和"直接改字段"相比没收益。
4. 翻译 Step 1 现在虽简陋但**工作正常**；"统一"是价值主张，不是刚需。如果近期没有"翻译路径也要 fallback"的具体需求，统一的收益只是账面上的。

**综合判断**：只消除 RecordingController 内部 200 行、不动 TranslationPipeline，收益一般（ROI 刚及格）；同时把 TranslationPipeline Step 1 也切过去，ROI 明显转正。**要做就一起做**，只拆一半反而多欠一份债。

---

## 4. 实施步骤（若决定做）

按可回滚顺序：

1. **新建 `Core/TranscriptionPipeline.swift`**，把三个私有方法搬过去，补 init/callbacks。
2. **`RecordingController` 改用 pipeline**，删本地实现。把 `stopCloudRecording` / `stopLocalRecording` 简化为"校验 → 启动 pipeline"。保持 `enterFallbackMode` 逻辑不变，改成由 `onFallbackEntered` 触发。
3. `make dev` 跑一轮：短录音 / 长录音 / 拔网 fallback / local 未 ready fallback 四条路径人工验证。
4. **`TranslationPipeline` 接入同一个 pipeline**（或让 RecordingController 把 pipeline 传进 TranslationPipeline 的构造器）。
5. 再跑一轮：翻译模式下拔网确认能 fallback 到 local 转录再继续翻译。
6. 更新 `Core/CLAUDE.md`，新增 TranscriptionPipeline 一行。

每步独立可提交，单元测试覆盖 pipeline 的 priority / fallback / 超时三条分支（RecordingController 以前基本没法做单测，因为状态机和编排搅在一起——这是拆出来的额外收益）。

---

## 5. 结论

**建议拆**，但理由要看清楚：

- 主要动机：消除 RecordingController 与 TranslationPipeline 之间的转录代码重复；
- 次要动机：让 RecordingController 回归纯调度器角色，为单测打开口子；
- **如果只拆 RecordingController、不改 TranslationPipeline，不建议做**——那只是换个地方放代码，ROI 不够正。

风险主要是翻译路径下的 fallback 语义变化，通过日志和 `onFallbackEntered` 通知可以控制。建议在决定做之前，先确认一条：翻译模式下的转录步骤**应该**和转录模式一样做 fallback 吗？如果答案是"应该"——直接开工；如果答案是"不，翻译模式要锁定用户选的 engine"——那 Pipeline 接口要加一个 `allowFallback: Bool`，否则不要拆。
