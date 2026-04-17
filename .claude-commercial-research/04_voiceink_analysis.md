# VoiceInk 深度分析报告

> 调研日期: 2026-03-26
> 最新版本: v1.73 (2025-04-10)
> GitHub: https://github.com/Beingpax/VoiceInk
> 官网: https://tryvoiceink.com
> 开发者: Prakash Joshi Pax (独立开发者)
> 许可证: GPL v3.0 (开源)
> GitHub Stars: 4,500+ | Forks: 614 | Commits: 1,172 | Releases: 117

---

## Part 1: 功能分析

### 1.1 完整功能列表

#### 核心转录功能
- **本地离线转录**: 使用 whisper.cpp 运行 OpenAI Whisper 模型，100% 离线处理
- **Parakeet 模型支持**: 通过 FluidAudio SDK 运行 NVIDIA Parakeet 模型 (CoreML)，速度约为 Whisper 的 2.8x
- **Apple 原生语音识别**: 集成 macOS 自带的 Speech Framework (NativeAppleTranscriptionService)
- **云端转录**: 支持多种云端 API (Deepgram, ElevenLabs, Soniox, Mistral, Speechmatics, Groq)
- **流式转录 (Streaming)**: v1.70 起支持实时流式转录，支持 Nova 3, Scribe V2, Soniox V4, Mistral Real-time, Speechmatics, FluidAudio Parakeet 流式
- **100+ 语言支持**: 多语言转录能力
- **自定义词汇表 (Dictionary)**: 个人词汇训练，跨设备同步
- **填充词移除**: 可配置的 filler word 过滤 (如 "um", "uh")
- **文本格式化**: 自动文本格式化处理 (WhisperTextFormatter)
- **词语替换**: 自动词语替换规则 (WordReplacementService)

#### AI 增强功能 (需要外部 API Key)
- **AI 文本增强**: 语法纠正、措辞改进、格式化 (支持 OpenAI GPT-5.x, Google Gemini 3.x, Anthropic Claude)
- **AI 助手模式**: 语音触发 AI 对话，无需离开当前应用
- **上下文感知**: 截屏 + OCR 检测屏幕内容，提供上下文给 AI 增强
- **剪贴板上下文**: 读取剪贴板内容作为 AI 增强的上下文
- **自定义 Prompt**: 支持创建多个自定义 AI 增强 Prompt
- **Prompt 检测**: 自动识别语音中的 prompt 触发词 (PromptDetectionService)
- **本地 CLI 模式**: v1.73 起支持使用本地 AI 工具 (Claude CLI, Pi, Codex) 替代 API 调用 (LocalCLIService)
- **推理配置**: 支持 reasoning model 的配置 (ReasoningConfig)
- **Ollama 支持**: 可连接本地 Ollama 服务 (OllamaService)

#### Power Mode (核心差异化功能)
- **应用感知**: 自动检测当前活动窗口应用 (ActiveWindowService)
- **URL 感知**: 检测浏览器当前 URL (BrowserURLService)
- **Per-App 配置**: 每个应用可独立配置转录模式、AI 增强 Prompt、语言等
- **Emoji 管理**: Power Mode 带 emoji 标识
- **快捷键切换**: 键盘快捷键直接切换特定 Power Mode
- **Power Mode Session**: 会话级别的 Power Mode 管理

#### 录音与输入
- **系统级听写**: 全局热键在任何应用中触发录音
- **三种激活模式**: Toggle (切换), Push to Talk (按住说), Hybrid (混合) -- 每个快捷键可独立设置
- **Core Audio 录音**: 使用 AUHAL (Audio Unit Hardware Abstraction Layer)，不改变系统默认设备
- **16kHz 单声道 PCM**: 录音直接转换为转录引擎所需格式
- **音频电平计量**: 实时计算 averagePower / peakPower
- **自定义音效**: 支持自定义开始/停止录音音效
- **音频设备切换**: 菜单栏快速切换录音设备
- **媒体控制**: 录音时自动暂停媒体播放，录音结束恢复 (MediaRemoteAdapter)
- **VAD 模型管理**: 语音活动检测 (VADModelManager)

#### 文本输出
- **光标粘贴**: 将转录文本粘贴到当前光标位置 (CursorPaster)
- **AppleScript 粘贴方法**: 兼容更多应用
- **Power Mode 自动发送**: 可配置自动按下 Return/Shift+Return/Cmd+Return
- **跳过短转录**: 过滤过短的转录结果
- **非 QWERTY 键盘布局支持**: 修复了非标准键盘布局的粘贴问题

#### 文件转录
- **批量文件转录**: 支持多文件转录队列 (AudioFileTranscriptionManager)
- **多格式支持**: WAV, MP3, M4A, AMR, OGG, OGA, Opus, 3GP 等
- **文件处理**: 独立的 AudioFileProcessor

#### 历史与导出
- **转录历史**: 可搜索的历史记录窗口，全局快捷键访问
- **内联历史视图**: v1.73 新增
- **Prompt 选择器**: 历史记录中可重新选择 Prompt 增强
- **重新增强按钮**: 只重新运行 AI 增强而不重新转录
- **CSV 导出**: 转录记录导出为 CSV
- **日志导出**: 应用日志导出功能

#### UI/UX 设计
- **菜单栏应用**: 常驻菜单栏，不占 Dock 栏
- **Notch 录音器**: 利用 MacBook 刘海区域显示录音状态
- **迷你录音器**: 紧凑的录音面板
- **实时转录显示**: 流式转录时实时显示文本 (notch recorder)
- **滑动面板 UI**: v1.72 重新设计的界面
- **模型预热**: 启动时预热模型以减少首次延迟 (ModelPrewarmService)
- **开机自启动**: LaunchAtLogin 支持
- **自动更新**: Sparkle 框架更新

### 1.2 独特/有趣的功能

1. **Power Mode 应用感知系统**: 这是 VoiceInk 最核心的差异化功能。能根据当前活跃应用和 URL 自动切换转录配置，比如在 VS Code 中自动使用技术术语 Prompt，在 Twitter 中使用推文风格 Prompt。这种上下文自适应是其他语音转文字工具少见的。

2. **多引擎架构**: 同时支持 whisper.cpp、FluidAudio Parakeet、Apple Native Speech、以及 6+ 种云端 API，并且支持流式与批量两种模式，引擎可热切换。

3. **本地 CLI AI 增强**: v1.73 新增的 LocalCLIService 允许调用本地安装的 AI 工具 (如 Claude CLI) 做文本增强，避免 API 费用。

4. **自动学习词汇**: v1.73 实验性功能，自动从使用中学习新词汇。

5. **Core Audio AUHAL 录音**: 不使用 AVAudioEngine，而是直接使用底层 Core Audio AUHAL，避免改变系统默认音频设备，专业级音频处理。

### 1.3 定价模型

| 计划 | 价格 | 设备数 |
|------|------|--------|
| Solo | $25 | 1 台 Mac |
| Personal | $39 | 2 台 Mac |
| Extended | $49 | 3 台 Mac |

- **一次性购买**，终身更新，无订阅
- 7 天免费试用
- 学生折扣 (凭学生证)
- 30 天退款保证
- AI 增强功能需自备 API Key (额外成本)
- App Store 也有上架 (VoiceInk: AI Dictation)
- 也可通过 Homebrew 安装: `brew install --cask voiceink`

**竞品价格对比 (3年总成本)**:
- VoiceInk: $39.99 (一次性)
- Voibe: $99
- SuperWhisper: $254.97 ($84.99/年订阅)

### 1.4 用户评价

- **App Store 评分**: 4.9/5 (1,127 条评价)
- **第三方评测评分**: 7/10 (getvoibe.com)
- **GitHub Stars**: 4,500+

**优点反馈**:
- 价格极具竞争力，一次性付费
- 开源代码可审计隐私安全
- 离线处理速度快
- Power Mode 实用
- 开发者响应积极

**缺点反馈**:
- 无 VS Code / Cursor IDE 集成
- iOS 伴侣应用 bug 较多 (语言检测错误、功能缺失)
- 上下文感知依赖截屏 OCR 而非 Accessibility API，不如 SuperWhisper 的全文本访问精确
- AI 增强需要额外的 API Key 和费用
- 设置复杂度较高
- Parakeet 模型多语言检测问题
- 仅支持 Apple Silicon (不支持 Intel Mac)
- 需要 macOS 14+

---

## Part 2: 技术栈分析

### 2.1 语音转文字引擎

VoiceInk 采用多引擎架构，通过 `TranscriptionServiceRegistry` 统一管理:

#### 本地引擎
1. **whisper.cpp** (主引擎)
   - 通过 `LibWhisper.swift` 封装 whisper.cpp XCFramework
   - 需要手动编译: `git clone whisper.cpp && ./build-xcframework.sh`
   - 支持所有 Whisper 模型大小
   - `WhisperModelManager` 管理模型下载和切换
   - `WhisperModelWarmupCoordinator` 处理模型预热
   - `WhisperPrompt` 处理 Whisper 的 initial prompt (用于引导词汇)
   - `VADModelManager` 管理语音活动检测模型

2. **FluidAudio (Parakeet)**
   - NVIDIA Parakeet 模型的 CoreML 实现
   - `FluidAudioModelManager` 管理 Parakeet 模型
   - `FluidAudioTranscriptionService` 提供批量转录
   - `FluidAudioStreamingProvider` 提供流式转录
   - 利用 Apple Neural Engine 加速，比 Whisper 快约 2.8x

3. **Apple Native Speech**
   - `NativeAppleTranscriptionService` 封装 macOS 原生 Speech Framework
   - 支持 BCP-47 格式的语言区域设置
   - 支持 11 种主要语言

#### 云端引擎
4. **CloudTranscriptionService** 统一处理多种云端 API:
   - Deepgram (Nova 3)
   - ElevenLabs (Scribe V2)
   - Soniox (V4)
   - Mistral (Voxtral)
   - Speechmatics
   - Groq
   - OpenAI Compatible (通用接口: `OpenAICompatibleTranscriptionService`)
   - 自定义模型 (`CustomModelManager`)

#### 流式转录
5. **StreamingTranscriptionService** 管理流式会话:
   - `DeepgramStreamingProvider`
   - `ElevenLabsStreamingProvider`
   - `FluidAudioStreamingProvider` (本地 Parakeet 流式)
   - `MistralStreamingProvider`
   - `SonioxStreamingProvider`
   - `SpeechmaticsStreamingProvider`
   - `WordAgreementEngine` 处理流式转录文本的稳定性
   - 支持 fallback: 流式模型可自动回退到批量模型

### 2.2 核心依赖

| 依赖 | 用途 |
|------|------|
| **whisper.cpp** | 本地 Whisper 模型推理 (XCFramework) |
| **FluidAudio** | NVIDIA Parakeet 模型 CoreML 推理 |
| **LLMkit** | AI 增强 LLM 调用抽象层 |
| **Sparkle** | 应用自动更新 |
| **KeyboardShortcuts** | 全局键盘快捷键 (sindresorhus) |
| **LaunchAtLogin** | 开机自启动 (sindresorhus) |
| **MediaRemoteAdapter** | 媒体播放控制 (录音时暂停/恢复) |
| **SelectedTextKit** | 获取当前选中文本 |
| **Swift Atomics** | 线程安全原子操作 |
| **Zip** | 压缩工具 |

**注意**: 不使用 WhisperKit，而是直接基于 whisper.cpp 的 C 库构建 XCFramework。

### 2.3 本地 vs 云端转录处理

```
TranscriptionServiceRegistry (统一注册表)
├── LocalTranscriptionService        -> whisper.cpp 本地转录
├── FluidAudioTranscriptionService   -> Parakeet CoreML 本地转录
├── NativeAppleTranscriptionService  -> macOS Speech Framework
├── CloudTranscriptionService        -> 各种云端 API
└── StreamingTranscriptionService    -> 流式转录 (本地+云端)
    └── TranscriptionSession
        ├── StreamingTranscriptionSession (流式 + fallback)
        └── FileTranscriptionSession (文件批量)
```

选择逻辑: 根据 `ModelProvider` 枚举值 (`.local`, `.fluidAudio`, `.nativeApple`, 以及各云端 provider) 路由到对应的 Service。流式模型如果失败，会自动 fallback 到对应的批量模型。

### 2.4 AI 文本处理管线

```
录音结束
  ↓
TranscriptionPipeline.run()
  ↓
1. 转录 (session.transcribe 或 serviceRegistry.transcribe)
  ↓
2. TranscriptionOutputFilter.filter()  -- 输出过滤
  ↓
3. trim whitespace
  ↓
4. WhisperTextFormatter.format()       -- 文本格式化 (可选)
  ↓
5. WordReplacementService.applyReplacements()  -- 词语替换
  ↓
6. PromptDetectionService              -- Prompt 触发词检测
  ↓
7. AIEnhancementService.enhance()      -- AI 增强 (可选，需 API Key)
   ├── 收集上下文: 屏幕截图 OCR + 剪贴板 + 自定义词汇
   ├── 选择 Prompt (Power Mode 或用户选择)
   ├── 调用 LLM (OpenAI/Anthropic/Gemini/Ollama/本地CLI)
   └── AIEnhancementOutputFilter       -- AI 输出过滤
  ↓
8. 保存到 SwiftData
  ↓
9. CursorPaster.paste()                -- 粘贴到光标位置
  ↓
10. 播放停止音效
```

### 2.5 音频录制实现

`CoreAudioRecorder` 使用底层 Core Audio AUHAL (Audio Unit Hardware Abstraction Layer):

- **不使用 AVAudioEngine**: 直接操作 AudioUnit，避免改变系统默认音频设备
- **16kHz 单声道 PCM Int16**: 在录制回调中实时转换为转录引擎所需的格式
- **预分配缓冲区**: `renderBuffer` 和 `conversionBuffer` 在初始化时分配，避免实时回调中的 malloc
- **线程安全**: 使用 NSLock 保护音频电平数据
- **流式音频输出**: `onAudioChunk` 回调用于将 PCM 数据实时传给流式转录引擎
- **支持外部音频设备**: 可选择任意输入设备，包括蓝牙耳机

### 2.6 数据存储

- **SwiftData**: 使用 Swift 原生数据框架存储转录记录 (`Transcription` model)
- **UserDefaults**: 存储用户设置和偏好
- **Keychain**: 通过 `KeychainService` 安全存储 API Key
- **JSON 编码**: Custom Prompts 等复杂数据结构

### 2.7 架构决策亮点

1. **TranscriptionServiceRegistry 模式**: 统一的服务注册表管理所有转录引擎，通过 `ModelProvider` 路由，新增引擎只需注册新 Service
2. **TranscriptionSession 抽象**: 流式和文件转录统一为 Session 接口，Pipeline 无需关心底层差异
3. **Pipeline 模式**: `TranscriptionPipeline` 将整个后处理流程线性化，每一步可独立测试和配置
4. **Power Mode 解耦**: Power Mode 通过 `PowerModeSessionManager` 与引擎解耦，通过 NotificationCenter 通信
5. **CoreAudio 直接操作**: 避免了 AVAudioEngine 的诸多问题 (设备切换、权限、延迟)
6. **GPL v3 开源但不接受 PR**: 代码透明但保持开发控制权

---

## Part 3: WhisperUtil 可以学习什么

### 3.1 值得采纳的功能

1. **Power Mode / 应用感知配置**
   - VoiceInk 最强的差异化功能。WhisperUtil 目前没有类似能力。
   - 实现思路: 检测当前活跃应用 (NSWorkspace.shared.frontmostApplication)，根据预配置自动切换 Prompt 或转录参数。
   - 对 WhisperUtil 的价值: 可以在不同应用中使用不同的 AI 后处理策略，比如在代码编辑器中保留技术术语，在邮件中自动润色。

2. **词语替换 (Word Replacement)**
   - 简单但实用: 将转录中的特定词汇自动替换为正确写法。
   - 比如 "VS Code" 可能被转录为 "vs code" 或 "visual studio code"，可以统一替换。
   - 实现简单，效果显著。

3. **模型预热 (Model Pre-warm)**
   - `ModelPrewarmService` 在应用启动时预加载模型，减少首次转录延迟。
   - WhisperUtil 可以借鉴: 在用户按下热键时模型已经就绪。

4. **转录历史搜索与管理**
   - 可搜索的转录历史窗口，支持重新增强 (re-enhance)。
   - WhisperUtil 目前缺乏历史记录管理。

5. **填充词移除 (Filler Word Removal)**
   - `FillerWordManager` 自动移除 "um", "uh", "嗯" 等填充词。
   - 简单的后处理步骤，显著提升输出质量。

6. **自定义开始/停止音效**
   - 让用户选择自己喜欢的音效，小功能但提升体验。

7. **多文件批量转录队列**
   - 支持拖入多个音频文件进行批量转录。
   - 扩展 WhisperUtil 的使用场景。

### 3.2 值得研究的技术方案

1. **Core Audio AUHAL 录音**
   - WhisperUtil 如果使用 AVAudioEngine 遇到设备切换问题，可以参考 VoiceInk 的 CoreAudioRecorder 实现。
   - 关键优势: 不改变系统默认设备，预分配缓冲区避免实时 malloc。

2. **TranscriptionPipeline 管线模式**
   - 将转录后处理拆分为独立的步骤 (过滤 -> 格式化 -> 替换 -> 检测 -> 增强)，每步可配置开关。
   - 更易于调试和扩展。

3. **流式转录的 WordAgreementEngine**
   - 处理流式转录文本的稳定性问题 (部分结果可能被后续结果推翻)。
   - WhisperUtil 的 Realtime 模式可以参考。

4. **FluidAudio / Parakeet 模型**
   - 作为 WhisperKit 的替代方案值得评估。Parakeet 在速度上有优势 (2.8x)。
   - FluidAudio 是一个独立的 Swift SDK，将 Parakeet 编译为 CoreML。

5. **LLMkit 抽象层**
   - VoiceInk 使用 LLMkit 统一多个 LLM Provider 的调用接口。
   - WhisperUtil 如果要支持多种 AI 增强后端，可以参考这种抽象。

6. **LocalCLIService 本地 AI 工具调用**
   - 直接调用本地安装的 AI CLI 工具 (Claude, Codex)，避免 API 费用。
   - 创新的思路，对开发者用户特别有吸引力。

### 3.3 VoiceInk 做得更好的地方

1. **多引擎支持的广度**: 6+ 种云端 API、3 种本地引擎、6 种流式 Provider，选择极其丰富
2. **Power Mode 应用感知**: 这是真正的杀手级功能，WhisperUtil 完全没有
3. **价格策略**: 一次性 $25-49，开源代码，极具竞争力
4. **社区与生态**: 4,500+ Stars，活跃的 Issue 讨论，开发者响应及时
5. **文本后处理管线的完整性**: 从 filler word 到 word replacement 到 AI enhance 的完整管线
6. **开源透明度**: GPL v3 完全开源，用户可审计隐私声明

### 3.4 VoiceInk 做得不好或缺失的地方

1. **上下文感知质量**: 依赖截屏 OCR 而非 Accessibility API，精确度和效率都不如直接读取文本
2. **IDE 集成缺失**: 不支持 VS Code / Cursor 等开发工具的深度集成
3. **iOS 应用质量差**: 多个用户反馈 iOS 版本 bug 多、功能不完整
4. **Apple Silicon 限制**: 不支持 Intel Mac，排除了部分用户
5. **设置复杂度高**: 功能多导致配置项繁杂，新用户上手成本高
6. **AI 增强依赖外部 API Key**: 核心增强功能需要用户自行获取和配置 API Key
7. **不接受社区 PR**: 开源但封闭开发，限制了社区贡献
8. **macOS 14+ 限制**: 不支持 macOS 13 及更早版本
9. **缺乏翻译功能**: 相比 WhisperUtil 的翻译能力，VoiceInk 没有内置语音翻译
10. **WebSocket 实时 API 不如 WhisperUtil**: WhisperUtil 的 Realtime GA WebSocket 模式是直接连接 OpenAI，VoiceInk 的流式主要依赖第三方 Provider

### 3.5 WhisperUtil 的差异化优势

WhisperUtil 相比 VoiceInk 的独特优势:
- **翻译功能**: VoiceInk 缺乏内置翻译
- **OpenAI Realtime WebSocket**: 直接连接 OpenAI GA WebSocket API，VoiceInk 没有这个模式
- **gpt-4o-transcribe 云端模式**: 使用 OpenAI 最新的转录 API
- **WhisperKit 集成**: 使用 Apple 优化的 WhisperKit 而非原始 whisper.cpp
- **更轻量的设计**: 功能精简，上手简单

---

## 附录: 版本历史摘要

| 版本 | 日期 | 关键更新 |
|------|------|----------|
| v1.73 | 2025-04-10 | Parakeet 实时流式, Speechmatics, 本地 CLI, 多文件队列, 自动学习词汇 |
| v1.72 | 2025-03-19 | Per-shortcut 激活模式, Power Mode 自动发送, GPT 5.4/Gemini 3.1 |
| v1.71 | 2025-02-25 | Bug fixes (Parakeet, 字典同步, 非QWERTY键盘, Groq 404) |
| v1.70 | 2025-02-09 | 流式转录 (Nova 3, Scribe V2, Soniox V4, Mistral), 字典同步, 实时显示 |
| v1.69 | 2025-01-12 | 录音修复, 日志导出 |
| v1.67 | 2025-01-07 | Power Mode 快捷键, 历史窗口, GPT-5.2, 蓝牙延迟配置 |
| v1.66 | 2024-12-23 | Gemini 3 模型, 模型预热 |
| v1.62 | 2024-11-29 | 自定义音效, 许可证验证修复 |

---

## 来源

- [VoiceInk GitHub](https://github.com/Beingpax/VoiceInk)
- [VoiceInk 官网](https://tryvoiceink.com/)
- [VoiceInk App Store](https://apps.apple.com/us/app/voiceink-ai-dictation/id6751431158)
- [VoiceInk Review 2026 - Voibe](https://www.getvoibe.com/resources/voiceink-review/)
- [VoiceInk Review - Kuan-Hao Huang](https://kuanhaohuang.com/voiceink-speech-to-text-mac/)
- [Mac Dictation Comparison - Apps.Deals](https://blog.apps.deals/2025-04-23-superwhisper-vs-voiceink)
- [AI Dictation Differentiators - Substack](https://afadingthought.substack.com/p/best-ai-dictation-tools-for-mac)
- [Parakeet vs Whisper - MacParakeet](https://macparakeet.com/blog/whisper-to-parakeet-neural-engine/)
