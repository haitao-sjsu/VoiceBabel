# Apple 原生语音识别（SFSpeechRecognizer）调研

调研日期：2026-04-14

## 摘要

Apple 原生语音识别框架经历了两个时代：SFSpeechRecognizer（iOS 10 / macOS 10.15 起）和 SpeechAnalyzer（iOS 26 / macOS 26 起，WWDC 2025 发布）。SFSpeechRecognizer 免费使用，支持在线和离线模式，约 64 种语言（在线），但存在每次请求 1 分钟音频限制、每小时 1000 次请求上限、不支持中英混杂（code-switching）等硬伤。新一代 SpeechAnalyzer 完全在设备端运行，速度极快（比 Whisper 快 2x+），但语言支持仅约 40 个 locale，且不支持 Custom Vocabulary。对于 WhisperUtil 项目，**短期内不建议集成**——SFSpeechRecognizer 限制太多，SpeechAnalyzer 要求 macOS 26+ 且多语言支持远弱于 WhisperKit（100 种语言）。建议在 macOS 26 正式发布后重新评估 SpeechAnalyzer。

---

## Part 1：框架概述

### 1.1 SFSpeechRecognizer（旧 API）

| 属性 | 说明 |
|------|------|
| 所属框架 | Speech.framework |
| 引入版本 | iOS 10 (2016) / macOS 10.15 Catalina (2019) |
| 支持平台 | iOS, macOS, tvOS, visionOS |
| 核心类 | `SFSpeechRecognizer`, `SFSpeechRecognitionRequest`, `SFSpeechRecognitionTask` |
| 授权要求 | 需要用户授权（`NSSpeechRecognitionUsageDescription`）+ 麦克风权限 |
| 是否免费 | **完全免费**，无需 API Key，无需付费 |

SFSpeechRecognizer 是 Apple 在 WWDC 2016 (Session 509) 推出的语音识别 API，本质上是将 Siri 的语音识别能力开放给第三方开发者。它支持两种模式：在线（服务端识别）和离线（设备端识别）。

### 1.2 SpeechAnalyzer（新 API，iOS 26+）

| 属性 | 说明 |
|------|------|
| 所属框架 | Speech.framework（重构） |
| 引入版本 | iOS 26 / macOS 26 Tahoe (WWDC 2025) |
| 支持平台 | iOS, macOS, tvOS, visionOS（不支持 watchOS） |
| 核心类 | `SpeechAnalyzer`, `SpeechTranscriber`, `SpeechDetector` |
| 架构 | 模块化设计，基于 Swift Concurrency（async/await） |

SpeechAnalyzer 是 Apple 在 WWDC 2025 推出的下一代语音识别 API，**完全替代** SFSpeechRecognizer。核心改进：

- **完全设备端运行**，不发送数据到服务器
- **支持长音频**（讲座、会议、对话场景）
- **远场音频支持**（说话人不需要靠近麦克风）
- **自动语言管理**，无需用户手动选择语言
- **模型资产管理**，支持按需下载语言包

Apple 系统应用 Notes、Voice Memos、Journal 已在使用此引擎。

> **注意**：Apple 并未强制废弃 SFSpeechRecognizer，官方建议可以渐进式迁移。

---

## Part 2：支持的语言

### 2.1 SFSpeechRecognizer 语言支持

**在线模式（服务端识别）：** 约 64 种 locale，覆盖主流语言。可通过 `SFSpeechRecognizer.supportedLocales()` 在运行时获取完整列表。

**离线模式（设备端识别）：** 约 20-22 种语言（取决于设备型号和系统版本），包括：
- 英语（US, GB, AU, CA, IN）
- 中文普通话（zh_CN）、粤语（yue_CN, zh_HK）
- 日语、韩语
- 法语、德语、意大利语、西班牙语、葡萄牙语
- 俄语、土耳其语、阿拉伯语

### 2.2 SpeechAnalyzer / SpeechTranscriber 语言支持

`SpeechTranscriber.supportedLocales` 返回约 **40+ 个 locale**，覆盖以下语言：

| 语言 | Locale 变体 |
|------|------------|
| 阿拉伯语 | ar_SA |
| 丹麦语 | da_DK |
| 德语 | de_AT, de_CH, de_DE |
| 英语 | en_AU, en_CA, en_GB, en_IE, en_IN, en_NZ, en_SG, en_US, en_ZA |
| 西班牙语 | es_CL, es_ES, es_MX, es_US |
| 芬兰语 | fi_FI |
| 法语 | fr_BE, fr_CA, fr_CH, fr_FR |
| 希伯来语 | he_IL |
| 意大利语 | it_CH, it_IT |
| 日语 | ja_JP |
| 韩语 | ko_KR |
| 马来语 | ms_MY |
| 挪威语 | nb_NO |
| 荷兰语 | nl_BE, nl_NL |
| 葡萄牙语 | pt_BR |
| 俄语 | ru_RU |
| 瑞典语 | sv_SE |
| 泰语 | th_TH |
| 土耳其语 | tr_TR |
| 越南语 | vi_VN |
| 粤语 | yue_CN |
| 中文 | zh_CN, zh_HK, zh_TW |

### 2.3 多语种混杂（Code-Switching）支持

**结论：不支持。**

SFSpeechRecognizer 和 SpeechAnalyzer 都通过 `Locale` 对象初始化，**每次识别只能指定一种语言**。这意味着：

- 如果选择 `zh_CN`，英文单词会被强行转写为中文或被忽略
- 如果选择 `en_US`，中文语音会被忽略或产生乱码
- **无法在同一段音频中正确识别中英混杂的语音**

相比之下，OpenAI Whisper 模型天然支持多语言混杂识别（通过 multilingual 训练），WhisperKit 继承了这一能力。这是 Apple 原生方案最大的短板之一，对中国用户（日常中英混杂说话非常普遍）影响尤其大。

> SpeechAnalyzer 的"自动语言管理"功能可能会在句子间切换语言，但对于句子内的中英混杂（如"我需要一个 meeting 来讨论 roadmap"），仍无法处理。

---

## Part 3：在线 vs 离线模式

### 3.1 SFSpeechRecognizer

| 特性 | 在线模式 | 离线模式 |
|------|---------|---------|
| 网络要求 | 需要网络 | 无需网络 |
| 准确率 | 较高 | 较低 |
| 语言支持 | ~64 locale | ~20 locale |
| 延迟 | 受网络影响 | 较低 |
| 隐私 | 音频发送至 Apple 服务器 | 数据不离开设备 |
| 启用方式 | 默认行为 | 设置 `requiresOnDeviceRecognition = true` |

### 3.2 SpeechAnalyzer

SpeechAnalyzer **完全在设备端运行**，没有在线模式。语言模型需要预先下载到设备，可通过 `AssetInventory` API 检查和管理：

```swift
// 检查语言包是否已安装
let inventory = SpeechTranscriber.AssetInventory()
let status = await inventory.status(for: Locale(identifier: "zh_CN"))

// 下载语言包
await inventory.download(for: Locale(identifier: "zh_CN"))
```

---

## Part 4：流式识别能力（实时转录）

### 4.1 SFSpeechRecognizer 流式识别

SFSpeechRecognizer 支持实时流式识别，通过 `SFSpeechAudioBufferRecognitionRequest` 实现：

```swift
import Speech
import AVFoundation

let audioEngine = AVAudioEngine()
let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))!
let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

// 启用部分结果（流式输出）
recognitionRequest.shouldReportPartialResults = true

// 启用设备端识别（可选）
if speechRecognizer.supportsOnDeviceRecognition {
    recognitionRequest.requiresOnDeviceRecognition = true
}

let recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
    if let result = result {
        let text = result.bestTranscription.formattedString
        // 实时更新 UI
        if result.isFinal {
            // 最终结果
        }
    }
}

// 将麦克风音频送入识别器
let inputNode = audioEngine.inputNode
let recordingFormat = inputNode.outputFormat(forBus: 0)
inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
    recognitionRequest.append(buffer)
}

audioEngine.prepare()
try audioEngine.start()
```

**流式识别限制**：
- 单次识别最长 **1 分钟**（超时后自动停止）
- 部分结果可能不稳定，后续结果可能修正之前的文本

### 4.2 SpeechAnalyzer 流式识别

SpeechAnalyzer 使用 Swift Concurrency 的 AsyncSequence 模式，更加现代：

```swift
import Speech

let analyzer = SpeechAnalyzer()
let transcriber = SpeechTranscriber(locale: Locale(identifier: "en_US"))
analyzer.addModule(transcriber)

// 从麦克风流式输入
for await event in transcriber.events {
    switch event {
    case .transcription(let result):
        print(result.formattedString)
    default:
        break
    }
}
```

**SpeechAnalyzer 突破了 1 分钟限制**，支持长时间持续转录。

---

## Part 5：性能特征

### 5.1 速度基准测试

**SpeechAnalyzer vs Whisper（34 分钟视频转录测试，MacStories 实测）：**

| 工具 | 引擎 | 耗时 | 相对速度 |
|------|------|------|---------|
| Yap（SpeechAnalyzer） | Apple SpeechAnalyzer | **45 秒** | 1x（基准） |
| MacWhisper | Whisper Large V3 Turbo | 1 分 41 秒 | 2.2x 慢 |
| VidCap | Whisper | 1 分 55 秒 | 2.6x 慢 |
| MacWhisper | Whisper Large V2 | 3 分 55 秒 | 5.2x 慢 |

**Argmax 基准测试（earnings22 数据集）：**

| 引擎 | WER (词错率) | 速度因子（倍实时） |
|------|-------------|-------------------|
| Apple SpeechAnalyzer | 14.0% | 70x |
| WhisperKit base | 15.2% | 111x |
| WhisperKit small | 12.8% | 35x |

### 5.2 准确率特征

- SFSpeechRecognizer（在线）：整体准确率较好，但对专有名词、驼峰命名的技术术语表现不佳
- SFSpeechRecognizer（离线）：准确率明显低于在线模式
- SpeechAnalyzer：准确率与 Whisper 中等模型相当（WER ~14%），但**缺少 Custom Vocabulary 功能**（SFSpeechRecognizer 有此功能），无法为特定关键词提升准确率
- 所有方案对人名、专有名词的识别都不佳

### 5.3 延迟

- SFSpeechRecognizer 在线：首字延迟受网络影响，通常 500ms-2s
- SFSpeechRecognizer 离线：首字延迟较低，约 200-500ms
- SpeechAnalyzer：低延迟实时转录，Apple 宣称"无准确率妥协"

---

## Part 6：使用限制

### 6.1 SFSpeechRecognizer 限制

| 限制类型 | 具体数值 | 说明 |
|---------|---------|------|
| **单次请求音频时长** | **1 分钟** | 超过后自动停止，缓冲区请求尤其严格 |
| **每设备每小时请求数** | **1000 次** | 是设备级别限制，非应用级别 |
| **每设备每日请求数** | 未公开具体数值 | Apple 称设有"合理限制" |
| **每应用全局每日请求数** | 未公开具体数值 | Apple 称设有"合理限制" |
| **超限错误码** | Code=203 | `kAFAssistantErrorDomain`，提示 "Quota limit reached" |

**1 分钟限制是最大的硬伤**——对于 WhisperUtil 这样需要长时间听写的工具，必须实现分段录音和拼接逻辑，极大增加复杂度。

### 6.2 SpeechAnalyzer 限制

- **无时长限制**（支持长音频）
- **无请求次数限制**（完全本地运行）
- **需要下载语言模型**（首次使用需联网下载）
- **最低系统要求**：macOS 26 / iOS 26（2025 年秋季发布）

---

## Part 7：收费情况

### 7.1 SFSpeechRecognizer

**完全免费**。无需 API Key，无需付费订阅，无需 Apple Developer Program 付费会员（但分发应用需要）。使用限额内的调用不产生任何费用。

### 7.2 SpeechAnalyzer

**完全免费**。完全在设备端运行，无需网络请求，无需 API Key。

### 7.3 与 OpenAI API 成本对比

| 方案 | 费用 | 备注 |
|------|------|------|
| SFSpeechRecognizer | 免费 | 有使用限额 |
| SpeechAnalyzer | 免费 | 无限额，需 macOS 26+ |
| WhisperKit | 免费 | 开源，本地运行 |
| OpenAI Whisper API | $0.006/分钟 | 按使用量付费 |
| OpenAI gpt-4o-transcribe | $0.006/分钟 | 按使用量付费 |
| OpenAI Realtime API | $0.06/分钟（输入音频） | 按使用量付费 |

---

## Part 8：与 WhisperKit / whisper.cpp 的对比

| 特性 | SFSpeechRecognizer | SpeechAnalyzer | WhisperKit | whisper.cpp |
|------|-------------------|----------------|------------|-------------|
| **费用** | 免费 | 免费 | 免费（MIT） | 免费（MIT） |
| **离线支持** | 部分（20 语言） | 完全离线 | 完全离线 | 完全离线 |
| **语言数量** | ~64 locale（在线） | ~40 locale | **100+ 语言** | **100+ 语言** |
| **中英混杂** | **不支持** | **不支持** | **支持** | **支持** |
| **单次时长限制** | **1 分钟** | 无限制 | 无限制 | 无限制 |
| **速度** | 中等 | **极快（70x 实时）** | 快（35-111x） | 中等 |
| **准确率（WER）** | ~15-20% | ~14% | **12.8%（small）** | 取决于模型 |
| **流式识别** | 支持 | 支持 | 支持 | 支持 |
| **Custom Vocabulary** | 支持 | **不支持** | 不支持 | 不支持 |
| **最低 macOS 版本** | 10.15 | **26（Tahoe）** | 14.0 | 无限制 |
| **集成难度** | 低（系统 API） | 低（系统 API） | 中（SPM 依赖） | 高（C++ 绑定） |
| **模型管理** | 系统管理 | 系统管理 | 开发者管理 | 开发者管理 |
| **跨平台** | Apple only | Apple only | Apple only | **全平台** |
| **说话人分离** | 不支持 | 不支持 | 支持（SpeakerKit） | 不支持 |

### 关键结论

1. **WhisperKit 在多语言支持上有碾压性优势**（100 vs 40 语言），且支持 code-switching
2. **SpeechAnalyzer 速度最快**，但语言覆盖不足，且要求 macOS 26+
3. **SFSpeechRecognizer 的 1 分钟限制**对听写工具是致命缺陷
4. WhisperKit 的 WER 可通过选择更大模型进一步降低（large-v3: ~10%）

---

## Part 9：macOS 集成方式

### 9.1 SFSpeechRecognizer macOS 集成

**所需权限（Info.plist）：**

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>需要语音识别权限以将语音转为文字</string>
<key>NSMicrophoneUsageDescription</key>
<string>需要麦克风权限以录制语音</string>
```

**App Sandbox 配置（entitlements）：**

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

**完整 macOS 实时转录示例：**

```swift
import Speech
import AVFoundation

class AppleSpeechService: NSObject, SFSpeechRecognizerDelegate {
    private let speechRecognizer: SFSpeechRecognizer
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    
    init(locale: Locale = Locale(identifier: "zh-Hans")) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            fatalError("Speech recognizer not available for locale: \(locale)")
        }
        self.speechRecognizer = recognizer
        super.init()
        speechRecognizer.delegate = self
    }
    
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }
    
    func startListening() throws {
        // 取消之前的任务
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // 创建识别请求
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        
        request.shouldReportPartialResults = true
        
        // 如果支持设备端识别，启用它
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        
        // 启动识别任务
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result = result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self?.onFinalResult?(text)
                } else {
                    self?.onPartialResult?(text)
                }
            }
            if let error = error {
                self?.onError?(error)
                self?.stopListening()
            }
        }
        
        // 配置音频输入
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
    }
    
    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }
    
    // MARK: - SFSpeechRecognizerDelegate
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        // 处理可用性变化
    }
}
```

### 9.2 参考项目

- **Voxt** ([GitHub](https://github.com/hehehai/voxt))：macOS 菜单栏语音输入工具，使用 SFSpeechRecognizer，按住说话松开粘贴
- **Katip** ([GitHub](https://github.com/imdatceleste/katip))：基于 SFSpeechRecognizer 的 macOS 录音转写工具
- **VoiceInk** ([GitHub](https://github.com/Beingpax/VoiceInk))：macOS 语音转文字应用，同时支持 WhisperKit 和 Apple 原生引擎

---

## Part 10：已知问题和局限性

### 10.1 SFSpeechRecognizer 的核心问题

1. **1 分钟时长硬限制**：对于连续听写场景，必须实现复杂的分段录音和结果拼接逻辑
2. **不支持 code-switching**：无法处理中英混杂语音，对中国用户影响巨大
3. **离线准确率显著下降**：离线模式的 WER 远高于在线模式
4. **请求限额不透明**：每日限额具体数值未公开，可能在重度使用场景下触发
5. **部分结果不稳定**：流式识别的中间结果可能频繁修正，导致 UI 闪烁
6. **专有名词识别差**：人名、技术术语、驼峰命名等识别率低

### 10.2 SpeechAnalyzer 的核心问题

1. **系统版本要求过高**：需要 macOS 26（Tahoe），预计 2025 年秋季正式发布，用户普及至少需要 1-2 年
2. **语言支持有限**：仅 40 个 locale（vs WhisperKit 的 100+ 语言）
3. **不支持 code-switching**：与旧 API 一样的问题
4. **缺少 Custom Vocabulary**：无法为特定领域关键词提升准确率
5. **模型需下载**：不预装，首次使用需联网下载语言模型
6. **API 尚在 Beta**：截至调研时 SpeechAnalyzer 文档仍在 Beta 阶段，API 可能变化
7. **无说话人分离**：不支持多说话人区分

### 10.3 通用问题

- 两套 API 都不支持翻译功能（转录语言 A 输出语言 B）
- 都不支持标点符号自定义或格式控制
- 识别结果没有置信度分数（SFSpeechRecognizer 有 confidence 但粒度粗）

---

## Part 11：集成建议（针对 WhisperUtil）

### 11.1 是否值得集成？

**短期（2026 年内）：不建议。**

理由：
- SFSpeechRecognizer 的 1 分钟限制和不支持 code-switching 是硬伤
- SpeechAnalyzer 要求 macOS 26+，目前用户基数不够
- WhisperKit 已经提供了优秀的离线转录能力，多语言支持远超 Apple 原生方案

**中长期（macOS 26 普及后）：可考虑作为第三引擎。**

理由：
- SpeechAnalyzer 速度极快（70x 实时），适合对延迟敏感的短句听写
- 完全免费且无使用限额
- 系统原生 API，无需管理模型文件
- 可作为 WhisperKit 的补充：快速场景用 SpeechAnalyzer，高精度 / 多语言场景用 WhisperKit

### 11.2 如果要集成的架构建议

```
RecordingController
    +-- ServiceLocalWhisper      (WhisperKit, 高精度, 100+语言)
    +-- ServiceCloudOpenAI       (Cloud API, 最高精度)
    +-- ServiceRealtimeOpenAI    (WebSocket 流式)
    +-- ServiceAppleSpeech       (Apple 原生, 极速, 免费)  ← 新增
```

用户场景分流：
- **中英混杂 / 多语言**：WhisperKit 或 Cloud API
- **纯中文 / 纯英文快速听写**：Apple SpeechAnalyzer（最快）
- **需要最高准确率**：Cloud API（gpt-4o-transcribe）
- **离线 + 多语言**：WhisperKit

### 11.3 竞品参考

VoiceInk 的做法是将 Apple 原生引擎作为"极速模式"选项——用 Apple 原生获得最快的响应速度，但准确率略低于 Whisper 模型。这种定位是合理的，但对 WhisperUtil 而言，在 macOS 26 普及之前没有必要提前投入开发资源。

---

## 参考资料

- [Apple Developer Documentation: SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer)
- [Apple Developer Documentation: SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [WWDC 2025: Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Apple Technical Q&A QA1951: Speech Framework API Limits](https://developer.apple.com/library/archive/qa/qa1951/_index.html)
- [Argmax Blog: Apple SpeechAnalyzer and WhisperKit](https://www.argmaxinc.com/blog/apple-and-argmax)
- [MacStories: Apple's New Speech APIs Outpace Whisper](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/)
- [iOS 26 SpeechAnalyzer Guide (Anton Gubarenko)](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide)
- [DEV Community: WWDC 2025 SpeechAnalyzer](https://dev.to/arshtechpro/wwdc-2025-the-next-evolution-of-speech-to-text-using-speechanalyzer-6lo)
- [VoiceInk GitHub](https://github.com/Beingpax/VoiceInk)
- [Voxt GitHub](https://github.com/hehehai/voxt)
