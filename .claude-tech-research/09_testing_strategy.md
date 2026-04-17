# WhisperUtil 测试策略研究报告

## Part 1: 是否需要测试？

### 诚实评估

WhisperUtil 约 3000 行代码，单人开发，架构清晰（组合根 + 回调连接），模块职责分明。从投入产出比来看：

**不需要全面的测试覆盖。** 但需要针对性的测试。

原因分析：

1. **代码量小，心智负担可控**：一个开发者能记住 13 个文件的交互关系。全面测试的维护成本可能超过手动验证。

2. **大部分代码是系统 API 胶水**：AudioRecorder（AVAudioEngine）、HotkeyManager（NSEvent）、TextInputter（CGEvent）、ServiceRealtimeOpenAI（URLSessionWebSocketTask）——这些模块 80% 的代码是调用系统 API，单元测试需要大量 mock，投入高、收益低。

3. **但确实存在容易出 bug 的纯逻辑**：状态机转换、音频编码、配置加载、超时计算——这些是测试的甜蜜点。

### 不测试的风险（基于实际案例）

从代码中观察到的风险点：

1. **`playSound` 的 `dropFirst()` 不一致问题**：AppDelegate 中 `$defaultApiMode`/`$autoSendMode`/`$smartModeWaitDuration`/`$textCleanupMode` 都用了 `.dropFirst()`，但 `$playSound` 没有用。这意味着 playSound 的初始值会触发一次多余的 sink 回调。虽然当前逻辑中这不是 bug（只是多打一行日志），但如果 `onStateChange` 或 `onError` 也存在类似不一致，就可能产生实际 bug。**这类不一致性正是测试能发现的。**

2. **状态机边界条件**：RecordingController 的状态机有 5 个状态 x 多种触发事件的组合。例如：
   - 在 `processing` 状态按 ESC 只是设 `currentState = .idle`，但如果 API 回调已经在飞行中怎么办？回调到达时状态已经是 idle，`handleResult` 中的 `self?.currentState = .idle` 会再次触发 `onStateChange`（虽然值没变，`didSet` 仍然触发）。
   - `waitingToSend` 状态下开始新录音，`cancelSmartModeForNewRecording` 取消定时器后再 `startRecording`——如果此时定时器 callback 恰好在执行怎么办？

3. **AudioEncoder WAV 头构造**：手动构造的 44 字节 WAV 头如果有任何一个字段写错（字节序、大小计算），API 会静默拒绝或返回错误结果。这类二进制协议构造是测试的完美目标。

4. **multipart/form-data 构造**：ServiceCloudOpenAI 手动构造 HTTP body，boundary、换行符、Content-Type 任何一个细节错误都会导致 API 400。

5. **超时计算公式**：`min(max(minutes * 10, 5), 90)` 看似简单，但边界值（0秒音频、10分钟音频）是否符合预期？

### ROI 分析

| 测试类型 | 投入 | 收益 | ROI |
|---------|------|------|-----|
| AudioEncoder 单元测试 | 低（纯函数，无依赖） | 高（二进制格式错误难排查） | **极高** |
| RecordingController 状态机测试 | 中（需要 mock 依赖） | 高（状态转换 bug 影响核心功能） | **高** |
| ServiceCloudOpenAI multipart 构造测试 | 中（需要验证 HTTP body） | 中（已经稳定运行） | 中 |
| Constants/Config 值测试 | 极低 | 低（回归防护） | 中 |
| HotkeyManager 测试 | 高（需要模拟 NSEvent） | 低（手动测试更直观） | **低** |
| AudioRecorder 测试 | 极高（AVAudioEngine mock） | 低（系统 API 行为稳定） | **极低** |
| TextInputter 测试 | 高（CGEvent + 剪贴板） | 低（需要辅助功能权限） | **极低** |

**结论：选择性测试。只测纯逻辑模块，跳过系统 API 包装层。**

---

## Part 2: 可测试性分析

### 各模块可测试性评级

#### 容易测试（纯逻辑，无/少系统依赖）

| 模块 | 可测逻辑 | 测试难度 |
|------|---------|---------|
| **AudioEncoder** | `encodeToWAV()` 是纯函数：输入 Float 数组，输出 Data。可以验证 WAV 头正确性、PCM16 转换精度、空输入处理。`encodeToM4A()` 依赖 AVAudioFile 但可在测试环境运行。 | 简单 |
| **Constants** | 所有值都是 `static let`，可以验证值域合理性（如超时不为负、采样率合理）。 | 极简单 |
| **TextCleanupMode** | `from()` 方法、`displayName`、`rawValue` 映射。 | 极简单 |
| **Config** | `Config.load()` 组装逻辑。 | 简单 |

#### 中等难度（有部分可测逻辑，但需要 mock）

| 模块 | 可测逻辑 | 测试难度 |
|------|---------|---------|
| **RecordingController** | 状态机转换逻辑是核心价值。但构造函数需要 7 个依赖对象。需要创建 protocol 或 mock 对象。 | 中等（需重构） |
| **ServiceCloudOpenAI** | `calculateProcessingTimeout()` 是纯函数可直接测。multipart body 构造可以截取验证。但 `sendRequest` 耦合了 URLSession。 | 中等 |
| **HotkeyManager** | 状态机逻辑清晰，但 `handleFlagsChanged` 输入是 `NSEvent`，不好构造。可以将状态转换逻辑抽离。 | 中等（需重构） |
| **SettingsStore** | UserDefaults 读写可测，但 `@MainActor` 单例模式限制了测试隔离性。 | 中等 |

#### 难以测试（深度耦合系统 API）

| 模块 | 原因 |
|------|------|
| **AudioRecorder** | AVAudioEngine + CoreAudio + AVCaptureDevice，需要真实麦克风硬件 |
| **TextInputter** | CGEvent + NSPasteboard + 辅助功能权限，需要真实系统环境 |
| **ServiceRealtimeOpenAI** | URLSessionWebSocketTask + WebSocket 协议，需要真实服务器或 mock server |
| **ServiceLocalWhisper** | WhisperKit + CoreML 模型加载，需要 ~626MB 模型文件 |
| **NetworkHealthMonitor** | NWPathMonitor + Timer + URLSession，需要真实网络环境 |
| **AppDelegate** | 组合根，连接所有组件，集成测试级别 |

### 最高价值测试目标

按 "bug 可能性 x 影响范围" 排序：

1. **RecordingController 状态机**：最复杂的逻辑，5 个状态 x 多种事件 = 几十种组合。Bug 直接影响核心功能（录音/转录流程）。
2. **AudioEncoder.encodeToWAV()**：手动构造二进制格式，任何错误都会导致 API 拒绝音频。
3. **ServiceCloudOpenAI 超时计算**：影响用户等待体验和错误处理。
4. **HotkeyManager 手势状态机**：三种手势的区分逻辑，误判会触发错误操作。

---

## Part 3: 测试策略建议

### 3.1 单元测试（自动化）

#### AudioEncoder（优先级：P0）

```
测试 encodeToWAV():
- 正常输入: 验证 WAV 头各字段正确性（RIFF, fmt, data chunk）
- 验证 PCM16 转换精度: Float 0.5 → Int16 16383
- 空输入: 返回 nil
- 单采样: 最小有效输入
- 大量采样: 验证 fileSize 计算正确

测试 encodeToM4A():
- 正常输入: 返回非 nil 且 format == .m4a
- 空输入: 返回 nil
- 验证压缩比 > 1（确认确实进行了压缩）

测试 AudioFormat:
- filename 和 contentType 映射正确
```

#### ServiceCloudOpenAI（优先级：P1）

```
测试 calculateProcessingTimeout():
- 0 秒音频 → 5 秒超时（最小值）
- 30 秒音频 → 5 秒超时（0.5min * 10 = 5）
- 3 分钟音频 → 30 秒超时
- 10 分钟音频 → 90 秒超时（最大值）
- 30 分钟音频 → 90 秒超时（仍为最大值）

测试 WhisperError:
- 各 case 的 errorDescription 不为空
- networkError 可正确携带消息
```

#### TextCleanupMode（优先级：P2）

```
测试 from():
- "off" → .off
- "neutral" → .neutral
- 无效字符串 → .off（默认值）
- 空字符串 → .off

测试 displayName:
- 每个 case 返回非空中文名
```

#### Constants 值域验证（优先级：P2）

```
- sampleRate > 0
- realtimeSampleRate > sampleRate（24kHz > 16kHz）
- apiProcessingTimeoutMin < apiProcessingTimeoutMax
- optionHoldThreshold > 0 && < 1（合理范围）
- doubleTapWindow > optionHoldThreshold（双击窗口应大于按住阈值）
- minVoiceThreshold > 0 && < 1
```

#### RecordingController 状态机（优先级：P0，但需要重构）

```
需要测试的状态转换:
- idle + beginRecording → recording
- idle + toggleRecording → recording
- recording + stopRecording → processing
- recording + cancelRecording → idle
- processing + cancelRecording → idle（不真正取消 API）
- waitingToSend + toggleRecording → idle（取消发送）
- waitingToSend + beginRecording → recording（追加录音）
- error + beginRecording → recording（从错误恢复）
- error + 3s → idle（自动恢复）
- recording + toggleRecording → 调用 stopRecording

需要测试的验证逻辑:
- 音频太短 → 不调用 API，回到 idle
- 音量太低 → 不调用 API，回到 idle
- enableSilenceDetection = false → 跳过验证
```

### 3.2 集成测试

鉴于项目规模，不建议搭建正式的集成测试框架。但可以考虑：

1. **Config 加载集成测试**：验证 `Config.load()` 能正确组装 UserSettings + EngineeringOptions 的所有字段。
2. **AudioEncoder 端到端**：录制一段已知音频 → encodeToM4A → 验证文件可被 AVAudioFile 正常读取。

### 3.3 手动测试清单

以下测试无法自动化或自动化成本过高，建议维护为手动清单：

**音频硬件相关：**
- [ ] 默认麦克风录音正常
- [ ] 外接麦克风录音正常
- [ ] HDMI 显示器导致默认输入设备变更时的行为（已知问题场景）
- [ ] 麦克风被其他应用占用时的冲突检测
- [ ] 系统听写（Dictation）激活时的冲突检测

**三种 API 模式：**
- [ ] Local 模式：正常转录中文/英文
- [ ] Cloud 模式：正常转录
- [ ] Realtime 模式：正常流式转录
- [ ] 翻译模式（双击 Option）：中→英翻译
- [ ] 网络断开 → Cloud 自动回退到 Local
- [ ] 网络恢复 → 自动切回 Cloud

**快捷键手势：**
- [ ] Option 按住 >400ms → Push-to-Talk
- [ ] Option 单击 → 切换录音
- [ ] Option 双击 → 翻译模式
- [ ] ESC → 取消录音/处理
- [ ] Option + Cmd/Shift → 不触发（冲突避免）

**自动发送：**
- [ ] off 模式：录音后不发送
- [ ] always 模式：录音后自动按 Enter
- [ ] smart 模式：倒计时后发送，单击 Option 取消

**文本输入：**
- [ ] 剪贴板模式正常粘贴
- [ ] 粘贴后原剪贴板内容恢复
- [ ] 文本优化三种模式效果正确

**设置面板：**
- [ ] 所有设置项修改后立即生效
- [ ] 设置持久化（重启后保留）

### 3.4 快照/回归测试

**不适用本项目。** 原因：
- 没有 UI 视图层（菜单栏太简单不值得快照）
- 输出是文本字符串，不是可视化结果
- API 返回结果不确定（同一段音频每次转录可能略有不同）

---

## Part 4: 实施指南

### 4.1 向 Xcode 项目添加 XCTest

在 Xcode 中添加测试 target：

1. 打开 `WhisperUtil.xcodeproj`
2. File → New → Target → macOS → Unit Testing Bundle
3. Product Name: `WhisperUtilTests`
4. Target to be Tested: `WhisperUtil`
5. Language: Swift

或者通过命令行运行测试：

```bash
# 构建并运行测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project WhisperUtil.xcodeproj \
  -scheme WhisperUtil \
  -destination 'platform=macOS'
```

### 4.2 测试文件组织

```
WhisperUtilTests/
├── AudioEncoderTests.swift       # 音频编码纯逻辑测试
├── ConstantsTests.swift           # 常量值域合理性验证
├── TextCleanupModeTests.swift     # 枚举映射测试
├── TimeoutCalculationTests.swift  # API 超时计算测试
└── RecordingStateMachineTests.swift  # 状态机测试（需要 mock）
```

### 4.3 示例测试代码

#### 示例 1: AudioEncoder 测试（最高优先级）

```swift
import XCTest
@testable import WhisperUtil

final class AudioEncoderTests: XCTestCase {

    // MARK: - encodeToWAV

    func testEncodeToWAV_emptyInput_returnsNil() {
        let result = AudioEncoder.encodeToWAV(samples: [])
        XCTAssertNil(result)
    }

    func testEncodeToWAV_normalInput_returnsWAVFormat() {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0]
        let result = AudioEncoder.encodeToWAV(samples: samples)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.format, .wav)
    }

    func testEncodeToWAV_headerStructure() {
        let samples: [Float] = Array(repeating: 0.1, count: 100)
        guard let result = AudioEncoder.encodeToWAV(samples: samples) else {
            XCTFail("encodeToWAV returned nil")
            return
        }

        let data = result.data

        // WAV 文件最小 44 字节头 + 数据
        XCTAssertGreaterThanOrEqual(data.count, 44)

        // 验证 RIFF 标识
        let riff = String(data: data[0..<4], encoding: .ascii)
        XCTAssertEqual(riff, "RIFF")

        // 验证 WAVE 标识
        let wave = String(data: data[8..<12], encoding: .ascii)
        XCTAssertEqual(wave, "WAVE")

        // 验证 fmt 子块
        let fmt = String(data: data[12..<16], encoding: .ascii)
        XCTAssertEqual(fmt, "fmt ")

        // 验证 data 子块
        let dataChunk = String(data: data[36..<40], encoding: .ascii)
        XCTAssertEqual(dataChunk, "data")

        // 验证文件大小字段
        let expectedDataSize = samples.count * 2  // Int16 = 2 bytes
        let expectedFileSize = 36 + expectedDataSize
        let fileSizeBytes = data[4..<8]
        let fileSize = fileSizeBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(fileSize), expectedFileSize)

        // 验证总数据大小
        XCTAssertEqual(data.count, 44 + expectedDataSize)
    }

    func testEncodeToWAV_pcm16Conversion_precision() {
        let samples: [Float] = [0.0, 1.0, -1.0, 0.5, -0.5]
        guard let result = AudioEncoder.encodeToWAV(samples: samples) else {
            XCTFail("encodeToWAV returned nil")
            return
        }

        let data = result.data
        let pcmData = data[44...]

        // 每个采样 2 字节（Int16 小端序）
        XCTAssertEqual(pcmData.count, samples.count * 2)

        // 提取第一个采样（0.0 → 0）
        let sample0 = pcmData.withUnsafeBytes { buffer -> Int16 in
            buffer.load(fromByteOffset: 0, as: Int16.self)
        }
        XCTAssertEqual(sample0, 0)

        // 提取第二个采样（1.0 → Int16.max = 32767）
        let sample1 = pcmData.withUnsafeBytes { buffer -> Int16 in
            buffer.load(fromByteOffset: 2, as: Int16.self)
        }
        XCTAssertEqual(sample1, Int16.max)

        // 提取第三个采样（-1.0 → -Int16.max = -32767）
        let sample2 = pcmData.withUnsafeBytes { buffer -> Int16 in
            buffer.load(fromByteOffset: 4, as: Int16.self)
        }
        XCTAssertEqual(sample2, -Int16.max)
    }

    func testEncodeToWAV_audioFormatFields() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        guard let result = AudioEncoder.encodeToWAV(samples: samples) else {
            XCTFail("encodeToWAV returned nil")
            return
        }

        let data = result.data

        // AudioFormat = 1 (PCM), offset 20
        let audioFormat = data.withUnsafeBytes { buffer -> UInt16 in
            buffer.load(fromByteOffset: 20, as: UInt16.self)
        }
        XCTAssertEqual(audioFormat, 1)

        // NumChannels = 1 (mono), offset 22
        let numChannels = data.withUnsafeBytes { buffer -> UInt16 in
            buffer.load(fromByteOffset: 22, as: UInt16.self)
        }
        XCTAssertEqual(numChannels, 1)

        // SampleRate = 16000, offset 24
        let sampleRate = data.withUnsafeBytes { buffer -> UInt32 in
            buffer.load(fromByteOffset: 24, as: UInt32.self)
        }
        XCTAssertEqual(sampleRate, UInt32(Constants.sampleRate))

        // BitsPerSample = 16, offset 34
        let bitsPerSample = data.withUnsafeBytes { buffer -> UInt16 in
            buffer.load(fromByteOffset: 34, as: UInt16.self)
        }
        XCTAssertEqual(bitsPerSample, 16)
    }

    // MARK: - encodeToM4A

    func testEncodeToM4A_emptyInput_returnsNil() {
        let result = AudioEncoder.encodeToM4A(samples: [])
        XCTAssertNil(result)
    }

    func testEncodeToM4A_normalInput_returnsM4AFormat() {
        // 1 秒静音 @ 16kHz
        let samples = Array(repeating: Float(0.0), count: 16000)
        let result = AudioEncoder.encodeToM4A(samples: samples)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.format, .m4a)
        if let result = result {
            XCTAssertLessThan(result.data.count, samples.count * 4)
        }
    }

    // MARK: - AudioFormat

    func testAudioFormat_filename() {
        XCTAssertEqual(AudioEncoder.AudioFormat.m4a.filename, "audio.m4a")
        XCTAssertEqual(AudioEncoder.AudioFormat.wav.filename, "audio.wav")
    }

    func testAudioFormat_contentType() {
        XCTAssertEqual(AudioEncoder.AudioFormat.m4a.contentType, "audio/mp4")
        XCTAssertEqual(AudioEncoder.AudioFormat.wav.contentType, "audio/wav")
    }
}
```

#### 示例 2: 超时计算和常量验证测试

```swift
import XCTest
@testable import WhisperUtil

final class TimeoutCalculationTests: XCTestCase {

    // ServiceCloudOpenAI.calculateProcessingTimeout 是 private
    // 直接复制公式测试其逻辑

    private func calculateTimeout(audioDuration: TimeInterval) -> TimeInterval {
        let minutes = audioDuration / 60.0
        let timeout = minutes * 10
        return min(max(timeout, Constants.apiProcessingTimeoutMin), Constants.apiProcessingTimeoutMax)
    }

    func testTimeout_zeroAudio_returnsMinimum() {
        XCTAssertEqual(calculateTimeout(audioDuration: 0), Constants.apiProcessingTimeoutMin)
    }

    func testTimeout_shortAudio_returnsMinimum() {
        XCTAssertEqual(calculateTimeout(audioDuration: 30), Constants.apiProcessingTimeoutMin)
    }

    func testTimeout_mediumAudio_scalesLinearly() {
        XCTAssertEqual(calculateTimeout(audioDuration: 180), 30)
    }

    func testTimeout_longAudio_returnsMaximum() {
        XCTAssertEqual(calculateTimeout(audioDuration: 600), Constants.apiProcessingTimeoutMax)
    }

    func testTimeout_veryLongAudio_returnsMaximum() {
        XCTAssertEqual(calculateTimeout(audioDuration: 3600), Constants.apiProcessingTimeoutMax)
    }
}

final class ConstantsTests: XCTestCase {

    func testSampleRates_positive() {
        XCTAssertGreaterThan(Constants.sampleRate, 0)
        XCTAssertGreaterThan(Constants.realtimeSampleRate, 0)
    }

    func testRealtimeSampleRate_higherThanStandard() {
        XCTAssertGreaterThan(Constants.realtimeSampleRate, Constants.sampleRate)
    }

    func testTimeoutRange_valid() {
        XCTAssertGreaterThan(Constants.apiProcessingTimeoutMin, 0)
        XCTAssertGreaterThan(Constants.apiProcessingTimeoutMax, Constants.apiProcessingTimeoutMin)
    }

    func testVoiceThreshold_inValidRange() {
        XCTAssertGreaterThan(Constants.minVoiceThreshold, 0)
        XCTAssertLessThan(Constants.minVoiceThreshold, 1.0)
    }

    func testOptionKeyTiming_consistent() {
        XCTAssertGreaterThanOrEqual(Constants.doubleTapWindow, Constants.optionHoldThreshold)
    }

    func testURLs_validFormat() {
        XCTAssertNotNil(URL(string: Constants.whisperTranscribeURL))
        XCTAssertNotNil(URL(string: Constants.whisperTranslateURL))
        XCTAssertNotNil(URL(string: Constants.chatCompletionsURL))
        XCTAssertNotNil(URL(string: Constants.realtimeWebSocketURL))
    }
}
```

#### 示例 3: TextCleanupMode 测试

```swift
import XCTest
@testable import WhisperUtil

final class TextCleanupModeTests: XCTestCase {

    func testFrom_validStrings() {
        XCTAssertEqual(TextCleanupMode.from("off"), .off)
        XCTAssertEqual(TextCleanupMode.from("neutral"), .neutral)
        XCTAssertEqual(TextCleanupMode.from("formal"), .formal)
        XCTAssertEqual(TextCleanupMode.from("casual"), .casual)
    }

    func testFrom_invalidString_defaultsToOff() {
        XCTAssertEqual(TextCleanupMode.from("invalid"), .off)
        XCTAssertEqual(TextCleanupMode.from(""), .off)
        XCTAssertEqual(TextCleanupMode.from("OFF"), .off)
    }

    func testDisplayName_allCasesHaveNames() {
        let allCases: [TextCleanupMode] = [.off, .neutral, .formal, .casual]
        for mode in allCases {
            XCTAssertFalse(mode.displayName.isEmpty,
                "\(mode) displayName should not be empty")
        }
    }

    func testRawValue_roundTrip() {
        let allCases: [TextCleanupMode] = [.off, .neutral, .formal, .casual]
        for mode in allCases {
            XCTAssertEqual(TextCleanupMode(rawValue: mode.rawValue), mode)
        }
    }
}
```

### 4.4 CI 集成

#### GitHub Actions 配置

```yaml
# .github/workflows/test.yml
name: Tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

      - name: Build and Test
        run: |
          xcodebuild test \
            -project WhisperUtil.xcodeproj \
            -scheme WhisperUtil \
            -destination 'platform=macOS' \
            -resultBundlePath TestResults.xcresult \
            2>&1 | xcpretty

      - name: Upload Test Results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: TestResults.xcresult
```

#### 注意事项

1. **WhisperKit 依赖**：如果测试 target link 了 WhisperKit，CI 环境需要下载 SPM 依赖，显著增加 CI 时间。建议测试 target 只 link 被测模块，不 link WhisperKit。
2. **麦克风权限**：CI 环境没有麦克风，AudioRecorder 相关测试会失败。这也是为什么不测这个模块。
3. **API Key**：测试不应依赖真实 API key。ServiceCloudOpenAI 的网络请求测试应使用 URLProtocol mock。
4. **本地运行**：开发时用 `Cmd+U` 在 Xcode 中运行测试，或命令行 `xcodebuild test`。

---

## Part 5: 实践建议

### 最小可行测试（第一步实施）

**只做这三件事，立即获得最大价值：**

1. **AudioEncoderTests**（约 30 分钟）
   - WAV 头验证、PCM16 转换精度、M4A 编码可用性
   - 理由：二进制格式 bug 极难通过日志发现，一旦出错影响所有 Cloud API 调用

2. **ConstantsTests + TextCleanupModeTests**（约 15 分钟）
   - 值域合理性、枚举映射完整性
   - 理由：写起来极快，作为回归防护几乎零成本

3. **TimeoutCalculationTests**（约 15 分钟）
   - 边界值验证
   - 理由：超时参数直接影响用户体验

**总投入：约 1 小时。** 以上三组测试覆盖了项目中所有纯函数逻辑。

### 第二步（如果有余力）

4. **RecordingController 状态机测试**
   - 需要先做一步小重构：将 RecordingController 的依赖改为 protocol（引入 `AudioRecording`, `TranscriptionService` 等 protocol），然后用 mock 实现测试
   - 预估投入 2-3 小时（含重构）
   - 价值很高但投入也大，建议在状态机下次出 bug 时顺手做

### 果断跳过

- **AudioRecorder 测试**：需要真实硬件，mock AVAudioEngine 太痛苦
- **TextInputter 测试**：需要辅助功能权限和真实系统环境
- **HotkeyManager 测试**：手动测试更直观、更可靠
- **ServiceRealtimeOpenAI 测试**：WebSocket mock 复杂度高，且已有真实环境验证
- **ServiceLocalWhisper 测试**：需要 626MB 模型文件，CI 不实际
- **NetworkHealthMonitor 测试**：需要网络环境，mock NWPathMonitor 意义不大
- **UI 测试**：菜单栏 + SwiftUI 设置面板，测试投入完全不值得
- **集成测试**：项目太小，手动测试覆盖全流程只需 5 分钟

### 测试 vs 开发的平衡

对于这个规模的独立开发项目，建议的时间分配：

| 活动 | 时间占比 |
|------|---------|
| 功能开发 | 85% |
| 写测试 | 5%（只做上面"最小可行测试"列表） |
| 手动测试 | 10%（每次改动后快速跑一遍手动清单的相关项） |

**核心原则：只测试"写错了很难发现"的纯逻辑代码。系统 API 包装层的 bug 通过使用就能发现——不值得写测试。**
