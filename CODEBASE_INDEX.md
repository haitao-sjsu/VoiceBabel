# WhisperUtil Codebase Index

macOS 菜单栏语音转文字工具，支持本地 (WhisperKit)、云端 (HTTP API)、实时 (WebSocket) 三种模式。

## Architecture

```
main.swift -> AppDelegate (组合根)
                 |
                 +-- Config/Config <-- Config/UserSettings (用户偏好默认值)
                 |                 <-- Config/EngineeringOptions (工程级开关/密钥)
                 |                 <-- Config/Constants (编译期常量)
                 +-- Config/SettingsStore (UserDefaults 持久化 + ObservableObject)
                 +-- UI/StatusBarController (菜单栏 UI)
                 +-- UI/SettingsWindowController -> UI/SettingsView (SwiftUI 设置面板)
                 +-- HotkeyManager (Option 键手势检测)
                 +-- RecordingController (状态机 / 核心调度)
                 |       +-- Audio/AudioRecorder -> Audio/AudioEncoder
                 |       +-- Services/ServiceCloudOpenAI (HTTP 转写/翻译)
                 |       +-- Services/ServiceRealtimeOpenAI (WebSocket 流式转写)
                 |       +-- Services/ServiceLocalWhisper (WhisperKit 本地转写)
                 |       +-- Services/ServiceTextCleanup (GPT-4o-mini 文本优化)
                 |       +-- Utilities/TextInputter (文字输入到活动窗口)
                 +-- Utilities/NetworkHealthMonitor (网络恢复探测)
```

AppDelegate 通过 Combine (`$publisher`) 监听 SettingsStore 变更，实时驱动 RecordingController 和 StatusBarController 更新。

## Directory Structure

```
Root/           — 入口、组合根、核心逻辑、输入处理
Config/         — 配置管理 (用户偏好默认值、工程级选项、编译期常量、UserDefaults 持久化)
UI/             — 菜单栏 UI 控制器、SwiftUI 设置面板、设置窗口控制器
Services/       — 转写后端 (Cloud HTTP / Realtime WebSocket / Local WhisperKit / 文本优化)
Audio/          — 音频采集与编码
Utilities/      — 辅助模块 (文字输入、网络探测、日志)
WhisperUtil/    — 资源 (Assets, Storyboard)
```

组件间通过闭包/回调通信，在 `AppDelegate.setupComponents()` 中统一连接。设置变更通过 Combine 发布者实时传播。

---

## File Index

### Entry & Lifecycle

| File                  | Description                                                                                                                                                               |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **main.swift**        | 应用入口。创建 NSApplication，设置 `.accessory` 策略（无 Dock 图标），启动 run loop                                                                                                           |
| **AppDelegate.swift** | 组合根。初始化所有组件并通过回调连接。持有 SettingsStore 单例，通过 Combine `$publisher` 监听设置变更并实时更新 RecordingController 和 StatusBarController。异步预加载 WhisperKit 模型。管理 SettingsWindowController 生命周期 |

### Config/

| File                                | Description                                                                                                                                                                                                                                              |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Config/Config.swift**             | 配置结构体。`Config.load()` 从 `UserSettings`（用户偏好默认值）和 `EngineeringOptions`（工程选项）两个来源组装运行时配置，作为抽象层供其他组件初始化使用                                                                                                                                                   |
| **Config/UserSettings.swift**       | 用户可配置偏好的硬编码默认值（语言、API 模式、发送模式、文本优化模式、提示音等）。作为 SettingsStore 的 fallback 默认值。工程级选项已迁移到 EngineeringOptions                                                                                                                                                  |
| **Config/EngineeringOptions.swift** | 工程级配置选项——控制音频处理管线各阶段的开关和参数。包括：API 密钥、模型选择（whisperModel / localWhisperModel）、静音检测开关、音频压缩开关、网络回退开关、Realtime delta 模式、繁简转换、标签过滤、翻译方法（whisper / two-step）、文本输入方式、最长录音时长。**包含 API 密钥，不可提交 git**                                                               |
| **Config/Constants.swift**          | 编译期常量命名空间。音频参数（采样率 16kHz/24kHz、RMS 阈值 0.001）、API 超时（5s~90s 动态）、API 端点 URL（transcriptions / translations / chat completions / realtime WebSocket）、AAC 编码（24kbps）、Option 键手势参数（按住阈值 400ms、双击窗口 500ms）、自动发送延迟、错误恢复延迟、网络探测间隔                                 |
| **Config/SettingsStore.swift**      | UserDefaults 持久化层 + ObservableObject 发布者。管理用户可调设置（API 模式、语言、提示音、发送模式、延迟时间、文本优化模式、翻译目标语言）。通过 `@Published` 属性自动写入 UserDefaults，初始化时从 UserDefaults 读取并 fallback 到 UserSettings 默认值。SwiftUI SettingsView 通过 `@ObservedObject` 绑定，AppDelegate 通过 Combine 监听变更 |

### UI/

| File                                  | Description                                                                                                                                        |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| **UI/StatusBarController.swift**      | 菜单栏 UI 控制器。管理 NSStatusItem 图标和精简下拉菜单：转录/翻译按钮、复制并粘贴上次转写、设置入口、关于、退出。根据应用状态动态更新图标和菜单项。定义 `ApiMode` 和 `AutoSendMode` 枚举。API 模式/发送模式等设置项已移至 Settings 面板 |
| **UI/SettingsView.swift**             | SwiftUI 设置面板视图。通过 SettingsStore（ObservableObject）双向绑定用户可调参数。三个 Section：语言（识别语言选择）、转写（API 模式、文本优化模式）、翻译（输出语言）、通用（发送模式、延迟时间、提示音）                     |
| **UI/SettingsWindowController.swift** | NSWindow 包装器。将 SwiftUI SettingsView 嵌入 NSHostingController，显示为独立的设置窗口（标题栏 + 关闭按钮，固定尺寸）。由 StatusBarController 的"设置..."菜单项触发                         |

### Core Logic

| File                          | Description                                                                                                                                                                                                                                                                                                                                                                                                             |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **HotkeyManager.swift**       | 全局快捷键管理。通过 NSEvent flagsChanged/keyDown 监听（全局 + 本地）检测 Option 键手势：按住 >400ms → Push-to-Talk（松开结束）、单击 → 切换长聊模式、双击 → 翻译模式。ESC 键取消录音/处理。冲突避免：Option+其他键/修饰键组合不触发                                                                                                                                                                                                                                                             |
| **RecordingController.swift** | **核心调度器**。状态机 `idle→recording→processing→waitingToSend→idle`（错误 3s 自动恢复）。根据 API 模式路由到不同转写流程：local（原始采样→WhisperKit）、cloud（M4A 编码→HTTP）、realtime（流式 PCM16→WebSocket）。翻译支持两种方法：Whisper API 直接翻译和两步法（转录+GPT 翻译），由 EngineeringOptions.translationMethod 控制。文本优化管线：转录结果经 ServiceTextCleanup 润色后再输出（翻译模式跳过）。自动发送逻辑（off/always/smart）。音频验证：最小数据量 + RMS 音量阈值（受 enableSilenceDetection 开关控制）。网络回退：Cloud API 失败时自动切换到本地 WhisperKit |

### Audio/

| File                          | Description                                                                                                                                                |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Audio/AudioRecorder.swift** | 录音模块。通过 AVAudioEngine + installTap 采集麦克风，AVAudioConverter 降采样至 16kHz/24kHz。两种模式：标准（内存缓冲，停止时编码 M4A）和流式（每个 chunk 即时转 PCM16 回调给 Realtime API）。检测麦克风可用性和系统听写冲突 |
| **Audio/AudioEncoder.swift**  | 音频编码。`encodeToM4A()`：Float32 采样→临时 AVAudioFile（AAC 16kHz 24kbps）→读回压缩数据。`encodeToWAV()`：手动构造 WAV（44 字节头 + PCM16），作为 M4A 失败的后备方案。压缩比约 20:1                  |

### Services/ (Transcription Backends)

| File                                     | Description                                                                                                                                                                                                                                            |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Services/ServiceCloudOpenAI.swift**    | OpenAI Whisper HTTP 客户端。`transcribe()`→`/v1/audio/transcriptions`（gpt-4o-transcribe），`translate()`→`/v1/audio/translations`（whisper-1 直接翻译），`translateTwoStep()`→先转录再用 GPT Chat Completions 翻译（更准确，支持多目标语言）。手动构造 multipart/form-data，动态超时。网络错误触发本地回退   |
| **Services/ServiceLocalWhisper.swift**   | WhisperKit 本地转写。模型 `openai_whisper-large-v3-v20240930_626MB`（首次自动下载）。温度回退策略（0.0 起步，0.2 递增，5 次重试），幻觉检测（压缩比 2.4），VAD 分块。后处理：过滤 `[MUSIC]`/`[BLANK_AUDIO]` 标签，繁转简（受 EngineeringOptions 开关控制）                                                               |
| **Services/ServiceRealtimeOpenAI.swift** | OpenAI Realtime WebSocket 流式转写。连接 `wss://api.openai.com/v1/realtime?intent=transcription`，配置 server_vad（阈值 0.5，静音 500ms），PCM16 输入。实时回调：`onTranscriptionDelta`（增量片段）、`onTranscriptionComplete`（完整结果）。连接状态机：disconnected→connecting→connected→configured |
| **Services/ServiceTextCleanup.swift**    | GPT-4o-mini 文本优化服务。通过 Chat Completions API 对转录结果进行润色/清理。三种模式：neutral（自然润色，去除填充词和口误）、formal（正式专业语气）、casual（轻松对话感）。严格保持原语言不翻译。失败时回退到原始文本，不丢失转录结果                                                                                                         |

### Utilities/

| File                                     | Description                                                                                                                |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| **Utilities/TextInputter.swift**         | 文字输入模块。剪贴板模式（默认）：保存→写入→模拟 Cmd+V→延迟恢复原内容。键盘模式：CGEvent 逐字符输入（支持 CJK）。`pressReturnKey()` 用于自动发送。需要辅助功能权限                      |
| **Utilities/NetworkHealthMonitor.swift** | 网络健康探测。NWPathMonitor 监听网络状态，定时 HEAD 请求 `api.openai.com/v1/models`（30s 间隔），成功后触发 `onCloudRecovered` 回调。在回退模式下启动，用户手动切换模式时停止 |
| **Utilities/Log.swift**                  | 日志工具。`Log.i/w/e/d()` 同时输出到控制台和文件 `~/Library/Containers/.../Logs/whisperutil.log`。                                          |

### Resources

| Path                       | Description                                                   |
| -------------------------- | ------------------------------------------------------------- |
| **WhisperUtil/**           | 资源目录：Assets.xcassets（图标、颜色）、Base.lproj/Main.storyboard        |
| **WhisperUtil.xcodeproj/** | Xcode 工程配置                                                    |

### Hidden Directories

| Path                            | Description                                                                                          |
| ------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **.claude-tech-research/**      | 技术调研：跨平台移植（Android/iOS）、Git + 多设备协作 + CI/CD、健壮性分析等                                              |
| **.claude-commercial-research/**| 商业化调研：竞品分析、开源模型评估、商业模式 + 云架构设计等                                                                  |
| **.claude-plan/**               | 开发计划与代码审查记录                                                                                        |
| **.learn/**                     | 学习笔记。受本杰明·富兰克林"从做中学"启发，通过手写复现代码库中的关键模块来加深理解（非项目运行代码）                                            |
