# WhisperUtil 跨平台移植研究报告

> 调研日期：2026-03-26

---

## 目录

- [Part 1: iOS 移植](#part-1-ios-移植)
- [Part 2: Android 移植](#part-2-android-移植)
- [Part 3: 代码共享策略](#part-3-代码共享策略)
- [Part 4: 自动化部署](#part-4-自动化部署)
- [附录：参考资源](#附录参考资源)

---

## Part 1: iOS 移植

### 1.1 Swift 代码复用分析

WhisperUtil 当前代码分为以下几层，复用程度各不同：

| 层级 | 文件 | iOS 复用程度 | 说明 |
|------|------|-------------|------|
| **Services/** | ServiceCloudOpenAI.swift | **95% 直接复用** | 纯 Foundation 网络代码，URLSession + multipart/form-data，iOS/macOS 完全一致 |
| **Services/** | ServiceRealtimeOpenAI.swift | **95% 直接复用** | URLSessionWebSocketTask 是跨平台 API，iOS 13+ 可用 |
| **Services/** | ServiceLocalWhisper.swift | **90% 直接复用** | WhisperKit 原生支持 iOS（由 argmaxinc 维护），API 完全相同，仅模型路径可能不同 |
| **Services/** | ServiceTextCleanup.swift | **100% 直接复用** | 纯 HTTP 调用 GPT-4o-mini |
| **Audio/** | AudioRecorder.swift | **60% 需修改** | AVAudioEngine API 相同，但需要改动：(1) 移除 CoreAudio 麦克风占用检测（macOS 特有），(2) 移除系统听写冲突检测，(3) 添加 AVAudioSession 配置 |
| **Audio/** | AudioEncoder.swift | **90% 直接复用** | AVAudioFile + AAC 编码在 iOS 上相同 |
| **Config/** | Config.swift, Constants.swift | **95% 直接复用** | 纯数据结构 |
| **Config/** | SettingsStore.swift | **85% 直接复用** | UserDefaults + @Published 在 iOS 上完全可用，但 key 命名空间可能需调整 |
| **Core** | RecordingController.swift | **80% 需修改** | 核心状态机逻辑可复用，但需改动：(1) 后台任务处理，(2) 移除 macOS 特有的 NSApplication 引用 |
| **Core** | HotkeyManager.swift | **0% 无法复用** | NSEvent 全局监听是 macOS 专属，iOS 需要完全不同的触发机制 |
| **UI/** | 全部 | **0% 需重写** | NSStatusItem/NSMenu 是 macOS 专属 |
| **Utilities/** | TextInputter.swift | **0% 无法复用** | CGEvent 键盘模拟、剪贴板 Cmd+V 都是 macOS 专属 |
| **Utilities/** | NetworkHealthMonitor.swift | **95% 直接复用** | NWPathMonitor 跨平台可用 |
| **Utilities/** | Log.swift | **90% 需微调** | 文件路径从 Container 改为 iOS 沙盒路径 |

**总结：约 60-65% 的业务逻辑代码可直接或微调后复用。** 需要完全重写的是 UI 层、快捷键触发和文字输入模块。

### 1.2 音频录制关键差异

#### AVAudioSession（iOS 必需，macOS 不需要）

iOS 上使用 AVAudioEngine 前必须配置 AVAudioSession，这是 macOS 和 iOS 最大的区别：

```swift
// iOS 专有代码，macOS 不需要
let session = AVAudioSession.sharedInstance()
try session.setCategory(.record, mode: .measurement, options: [])
try session.setActive(true)
```

如果需要录音时播放提示音，category 需改为 `.playAndRecord`。

#### 麦克风权限

- **macOS**：当前代码通过 `AVCaptureDevice.authorizationStatus(for: .audio)` 检查，首次使用弹窗
- **iOS**：相同 API，但需要在 Info.plist 添加 `NSMicrophoneUsageDescription`
- **区别**：iOS 的权限更严格，用户拒绝后需引导到设置页面

#### 后台音频录制

这是最关键的限制：

- **macOS**：无限制，菜单栏 app 始终可录音
- **iOS**：App 进入后台后默认暂停录音。需要：
  1. 在 Info.plist 添加 `UIBackgroundModes` 中的 `audio`
  2. AVAudioSession category 设为 `.playAndRecord` 或 `.record`
  3. 即使如此，纯录音 app 在后台的存活时间也有限制
  4. **实际场景**：WhisperUtil 是按键触发短录音，用户录音时 app 在前台，这个限制影响不大

#### macOS 特有代码需移除

- `CoreAudio` 的 `AudioObjectGetPropertyData`（麦克风占用检测）：iOS 无此 API
- 系统听写冲突检测：iOS 不存在此问题（键盘听写不冲突）
- `import Cocoa`：改为 `import UIKit`

### 1.3 UI 迁移方案

macOS 版是 NSStatusItem 菜单栏应用，iOS 上没有对应概念。推荐方案：

#### 方案 A：极简单页面 App（推荐）

```
+-----------------------------+
|  WhisperUtil                |
|                             |
|  +-----------------------+  |
|  |                       |  |
|  |   [大录音按钮]         |  |  <- 长按录音 / 点击切换
|  |                       |  |
|  +-----------------------+  |
|                             |
|  转录结果：                  |
|  +-----------------------+  |
|  | "你好世界"             |  |  <- 可复制/分享
|  +-----------------------+  |
|                             |
|  [翻译] [设置]              |
+-----------------------------+
```

- 一个 SwiftUI View 即可
- 录音按钮支持长按（Push-to-Talk）和点击切换
- 结果区域支持复制、分享
- 设置用 `.sheet` 弹出，复用 SettingsView（稍作修改）

#### 方案 B：键盘扩展（IME）

- 作为自定义键盘 Extension，在任何 app 中使用语音输入
- 更接近 macOS 版的使用体验（任何位置输入文字）
- 但开发复杂度高，键盘 Extension 内存限制 50MB，可能无法加载本地 Whisper 模型
- 权限受限：键盘 Extension 默认无网络权限（需要用户开启"允许完全访问"）

#### 方案 C：Live Activity / Dynamic Island

- iOS 16+ 的 Live Activity 可以在锁屏/灵动岛显示录音状态
- 作为方案 A 的增强功能，不能独立使用

**建议：先做方案 A，成熟后考虑方案 B 键盘扩展。**

#### 触发方式替代 Option 键手势

iOS 上没有全局快捷键，替代方案：

1. **App 内长按按钮**：最直接
2. **Shortcuts (捷径) 集成**：通过 AppIntents 暴露"开始录音"动作，用户可设置 Siri 唤起或辅助功能快捷键
3. **Action Button（iPhone 15 Pro+）**：用户可将 Action Button 映射到 Shortcut
4. **控制中心按钮（iOS 18+）**：添加自定义控制中心按钮

### 1.4 分发方式

| 方式 | 适用场景 | 要求 |
|------|---------|------|
| **Xcode 直接安装** | 开发调试 | Apple ID（免费），设备连接 Mac，7 天有效期 |
| **TestFlight** | 内测分发 | Apple Developer Program ($99/年)，最多 10,000 测试者 |
| **Ad Hoc** | 小范围分发 | Developer Program，需注册设备 UDID，最多 100 台 |
| **App Store** | 公开发布 | Developer Program，App Review 审核 |

**对于个人使用：** 免费 Apple ID + Xcode 直接安装最简单，缺点是每 7 天要重新签名。加入 Developer Program 后可用 TestFlight 或 Ad Hoc，有效期 1 年。

### 1.5 工作量评估

| 任务 | 估计时间 |
|------|---------|
| 项目初始化 + 共享代码抽取 | 1 天 |
| AudioRecorder 适配 (AVAudioSession) | 0.5 天 |
| UI 开发 (SwiftUI 单页面 + 设置) | 1-2 天 |
| 录音触发机制 (长按 + Shortcuts) | 1 天 |
| 结果处理 (复制/分享/粘贴) | 0.5 天 |
| WhisperKit iOS 集成验证 | 0.5 天 |
| 测试 + 调试 | 1-2 天 |
| **总计** | **5-7 天** |

iOS 移植是最低成本的选择，因为 Swift + AVFoundation + WhisperKit 全栈共享。

---

## Part 2: Android 移植

### 2.1 语言选择

#### 方案对比

| 方案 | 语言 | 代码复用 macOS/iOS | Android 生态契合 | 音频 API 支持 | 推荐度 |
|------|------|-------------------|-----------------|--------------|--------|
| **原生 Kotlin** | Kotlin | 0%（需重写） | 最佳 | AudioRecord/Oboe 原生 | 最高 |
| **KMP** | Kotlin + Swift | 共享业务逻辑 30-40% | 良好 | 平台各自实现 | 中 |
| **Flutter** | Dart | 0%（全部重写） | 良好 | 插件可用 | 低 |
| **React Native** | TypeScript | 0%（全部重写） | 一般 | 需 Native Module | 最低 |

**推荐：原生 Kotlin。** 理由：

1. WhisperUtil 的核心是音频处理和 API 通信，这两个领域需要深度平台集成
2. 音频录制（AudioRecord）、WebSocket（OkHttp）、HTTP（Retrofit/OkHttp）在 Kotlin 生态都有成熟方案
3. 项目规模不大（约 15 个源文件），重写成本可控
4. KMP 在音频实时处理场景还不够成熟，内存管理需要额外关注
5. Flutter/RN 需要 Native Bridge 处理音频，增加复杂度且无实际收益

### 2.2 音频录制

#### AudioRecord API

Android 上录音推荐使用 `AudioRecord`（底层 API），而非 `MediaRecorder`（高层 API），因为需要原始 PCM 数据：

```kotlin
// 等价于 macOS 的 AVAudioEngine + installTap
val sampleRate = 16000
val bufferSize = AudioRecord.getMinBufferSize(
    sampleRate,
    AudioFormat.CHANNEL_IN_MONO,
    AudioFormat.ENCODING_PCM_16BIT
)

val audioRecord = AudioRecord(
    MediaRecorder.AudioSource.MIC,
    sampleRate,
    AudioFormat.CHANNEL_IN_MONO,
    AudioFormat.ENCODING_PCM_16BIT,
    bufferSize * 2
)

// 录音线程
thread {
    audioRecord.startRecording()
    val buffer = ShortArray(bufferSize)
    while (isRecording) {
        val read = audioRecord.read(buffer, 0, buffer.size)
        // 标准模式：累积到 audioBuffer
        // 流式模式：base64 编码后发送到 WebSocket
    }
    audioRecord.stop()
}
```

#### 与 macOS AVAudioEngine 的对应关系

| macOS (AVAudioEngine) | Android (AudioRecord) |
|-----------------------|----------------------|
| `installTap(onBus:)` 回调 | 后台线程 `read()` 循环 |
| `AVAudioConverter` 重采样 | 直接指定目标采样率（16kHz/24kHz） |
| Float32 格式 (-1.0~1.0) | PCM16 Short 格式 (-32768~32767) |
| `audioEngine.stop()` | `audioRecord.stop()` + `release()` |
| 系统自动管理音频路由 | 需要监听 `AudioManager` 路由变化 |

**优势：** Android AudioRecord 直接输出 PCM16，不需要像 macOS 那样先拿 Float32 再转 PCM16。Realtime API 所需的 PCM16 24kHz 格式可以直接录制。

#### 权限

AndroidManifest.xml 需要声明：

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<!-- 前台服务用于后台录音 -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
```

运行时权限请求（Android 6.0+）：

```kotlin
if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
    != PackageManager.PERMISSION_GRANTED) {
    ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 1)
}
```

#### 后台录音

Android 13+ 要求后台录音使用 Foreground Service：

```kotlin
// 启动前台服务，显示通知
val notification = NotificationCompat.Builder(this, CHANNEL_ID)
    .setContentTitle("WhisperUtil 正在录音")
    .setSmallIcon(R.drawable.ic_mic)
    .build()

startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
```

### 2.3 Whisper 本地推理方案

#### 方案对比

| 方案 | 模型格式 | 推理速度 | 多语言 | 模型大小 | 成熟度 | 推荐度 |
|------|---------|---------|--------|---------|--------|--------|
| **WhisperKit Android** | QNN/GPU 优化 | 最快（NPU 加速） | 是 | ~600MB (large-v3) | 早期（v0.3.x） | 关注 |
| **whisper.cpp + JNI** | GGML 量化 | 快（CPU/GPU） | 是 | ~40MB (tiny) ~ 1.5GB (large) | 成熟 | 首选 |
| **TFLite** | TFLite 量化 | 中等 | 有限 | ~40MB (量化) | 成熟 | 备选 |
| **ONNX Runtime** | ONNX | 中等 | 是 | 取决于模型 | 成熟 | 备选 |

#### 推荐方案：whisper.cpp（首选）+ WhisperKit Android（关注）

**whisper.cpp 理由：**
- 最成熟的跨平台 Whisper 实现，活跃维护
- 官方提供 Android 示例 app（JNI 集成）
- 支持 GGML 量化模型，可根据设备性能选择模型大小
- small.en 模型在现代 Android 手机上可实现接近实时转录（~2x realtime）
- 社区活跃，已有大量 Android 集成经验
- 参考项目：[F-Droid Whisper](https://f-droid.org/packages/org.woheller69.whisper/)、[Handy](https://github.com/cjpais/Handy)

**集成方式：**

```
项目结构:
app/
  src/main/java/com/whisperutil/  (Kotlin 代码)
  src/main/jni/                    (JNI 桥接)
    whisper_jni.cpp                (C++ <-> Kotlin 桥接)
    CMakeLists.txt
  src/main/assets/
    models/
      ggml-small.bin               (GGML 量化模型)
```

也可使用预编译的 whisper.cpp AAR 包，避免自己编译 NDK。

**WhisperKit Android 关注理由：**
- Argmax 与 Qualcomm 合作，针对 Snapdragon 芯片优化
- OnePlus 使用骁龙芯片，可获得 NPU 加速
- 但目前仍是早期版本（v0.3.3），功能是 iOS 版的子集
- 建议：先用 whisper.cpp，等 WhisperKit Android 成熟后迁移

#### 性能参考（whisper.cpp on Android）

- **batch 模式**（录完再转）：5 秒音频约 1-2 秒处理，完全可用
- **streaming 模式**（边录边转）：目前约 5x 慢于实时，不实用
- **建议**：Android 本地模式先只做 batch，不做 streaming（与 macOS 的 Local 模式一致）

### 2.4 OpenAI API 集成

#### HTTP API（Cloud 模式）

使用 OkHttp + multipart 请求，等价于 macOS 的 `ServiceCloudOpenAI`：

```kotlin
// OkHttp multipart/form-data
val requestBody = MultipartBody.Builder()
    .setType(MultipartBody.FORM)
    .addFormDataPart("model", "gpt-4o-transcribe")
    .addFormDataPart("language", "zh")
    .addFormDataPart("file", "audio.m4a",
        audioData.toRequestBody("audio/mp4".toMediaType()))
    .build()

val request = Request.Builder()
    .url("https://api.openai.com/v1/audio/transcriptions")
    .addHeader("Authorization", "Bearer $apiKey")
    .post(requestBody)
    .build()

// 异步调用
client.newCall(request).enqueue(object : Callback { ... })
```

#### WebSocket API（Realtime 模式）

使用 OkHttp WebSocket，等价于 macOS 的 `ServiceRealtimeOpenAI`：

```kotlin
val request = Request.Builder()
    .url("wss://api.openai.com/v1/realtime?intent=transcription")
    .addHeader("Authorization", "Bearer $apiKey")
    .addHeader("OpenAI-Beta", "realtime=v1")
    .build()

val webSocket = client.newWebSocket(request, object : WebSocketListener() {
    override fun onOpen(webSocket: WebSocket, response: Response) {
        // 发送 transcription_session.update 配置
        val config = JSONObject().apply {
            put("type", "transcription_session.update")
            put("session", JSONObject().apply {
                put("input_audio_format", "pcm16")
                // ... VAD 配置等
            })
        }
        webSocket.send(config.toString())
    }

    override fun onMessage(webSocket: WebSocket, text: String) {
        // 解析 transcription delta / complete 事件
    }
})

// 发送音频数据
fun sendAudioChunk(pcm16Data: ByteArray) {
    val base64 = Base64.encodeToString(pcm16Data, Base64.NO_WRAP)
    val event = JSONObject().apply {
        put("type", "input_audio_buffer.append")
        put("audio", base64)
    }
    webSocket.send(event.toString())
}
```

已有开源参考项目：[openai-realtimeapi-android-agent](https://github.com/klomash/openai-realtimeapi-android-agent)

#### 音频编码（M4A/AAC）

Android 使用 `MediaCodec` 编码 AAC，等价于 macOS 的 `AudioEncoder`：

```kotlin
val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, 16000, 1)
format.setInteger(MediaFormat.KEY_BIT_RATE, 24000)
format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
```

然后用 `MediaMuxer` 封装为 M4A 容器。

### 2.5 从 MacBook 部署到 OnePlus 手机

#### ADB 设置

1. **安装 ADB：**
```bash
# 通过 Homebrew
brew install android-platform-tools

# 或通过 Android Studio 自动安装
# 路径：~/Library/Android/sdk/platform-tools/adb
```

2. **OnePlus 开启开发者选项：**
- 设置 > 关于手机 > 连续点击"版本号" 7 次
- 设置 > 系统 > 开发者选项 > 开启 USB 调试
- ColorOS 还需要开启"禁用权限监控"（部分版本）

3. **USB 连接：**
```bash
adb devices  # 确认设备已连接
# 首次连接需要在手机上确认授权
```

4. **安装 APK：**
```bash
# Debug 版本
adb install -r app/build/outputs/apk/debug/app-debug.apk

# 或直接从 Android Studio: Run > Run 'app'
```

#### Debug 签名

Android Studio 自动生成 debug keystore，位于 `~/.android/debug.keystore`，无需手动配置。Debug 签名的 APK 可直接安装到手机。

#### Release 签名

```bash
# 生成 keystore
keytool -genkey -v -keystore whisperutil-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias whisperutil
```

在 `app/build.gradle.kts` 配置签名：

```kotlin
android {
    signingConfigs {
        create("release") {
            storeFile = file("whisperutil-release.jks")
            storePassword = "..."
            keyAlias = "whisperutil"
            keyPassword = "..."
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }
}
```

### 2.6 ColorOS 特殊处理

OnePlus 使用 ColorOS（合并自 OxygenOS），对后台应用有 **激进的电池优化**，是 Android OEM 中限制最严的之一。参考 [Don't Kill My App - OnePlus](https://dontkillmyapp.com/oneplus)。

#### 必须处理的问题

**1. 电池优化白名单**

引导用户手动设置：

```kotlin
// 检查是否在白名单
val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
if (!pm.isIgnoringBatteryOptimizations(packageName)) {
    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
    intent.data = Uri.parse("package:$packageName")
    startActivity(intent)
}
```

**2. App Auto-Launch 设置**

ColorOS 有独立的"自启动管理"，默认禁止后台自启动。需要引导用户：
- 设置 > 应用管理 > 应用列表 > WhisperUtil > 允许自启动

**3. 后台限制**

ColorOS 的 Deep Optimization 会在屏幕关闭后积极杀后台进程。解决方案：
- 使用 Foreground Service + 通知（最有效）
- 引导用户关闭"高级优化"：设置 > 电池 > 高级优化 > 关闭
- 在最近任务中"锁定"应用

**4. 麦克风权限**

ColorOS 有"权限层级确认"机制，录音权限需要用户明确同意。且 ColorOS 可能在后台时撤销麦克风权限。解决方案：
- 每次录音前检查权限状态
- 使用 Foreground Service 保持前台状态

**5. 代码中的防护**

```kotlin
// 在 app 首次启动时引导用户完成设置
class OnePlusOptimizationHelper {
    fun showOptimizationGuide(context: Context) {
        val isColorOS = Build.MANUFACTURER.equals("OnePlus", ignoreCase = true)
                || Build.BRAND.equals("OnePlus", ignoreCase = true)

        if (isColorOS) {
            // 显示引导弹窗，分步骤引导用户：
            // 1. 关闭电池优化
            // 2. 允许自启动
            // 3. 关闭高级优化
            // 4. 锁定最近任务
        }
    }
}
```

### 2.7 macOS 上的 Android 开发环境搭建

#### 必装软件

```bash
# 1. Android Studio (包含 SDK, Emulator, Gradle)
# 下载: https://developer.android.com/studio
# 或 brew:
brew install --cask android-studio

# 2. JDK (Android Studio 自带 JBR，也可独立安装)
brew install openjdk@17

# 3. ADB (如果不想装完整 Android Studio)
brew install android-platform-tools
```

#### SDK 和 NDK（whisper.cpp 需要）

通过 Android Studio > Settings > SDK Manager 安装：

- **SDK Platforms**: Android 14 (API 34) 或更高
- **SDK Tools**:
  - Android SDK Build-Tools
  - Android SDK Platform-Tools
  - NDK (Side by side) -- whisper.cpp JNI 编译需要
  - CMake -- whisper.cpp 构建需要

NDK 也可通过命令行安装：

```bash
sdkmanager "ndk;26.1.10909125" "cmake;3.22.1"
```

#### 环境变量

```bash
# ~/.zshrc
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=$PATH:$ANDROID_HOME/platform-tools
export PATH=$PATH:$ANDROID_HOME/tools
```

#### 项目创建建议

```
推荐项目模板: Empty Compose Activity (Jetpack Compose)
最低 API: 26 (Android 8.0) -- 覆盖 99% 设备
目标 API: 34 (Android 14)
语言: Kotlin
构建系统: Gradle (Kotlin DSL)
```

### 2.8 Android 版工作量评估

| 任务 | 估计时间 |
|------|---------|
| 环境搭建 + 项目初始化 | 0.5 天 |
| 音频录制模块 (AudioRecord) | 1 天 |
| AAC 编码 (MediaCodec + MediaMuxer) | 1 天 |
| Cloud API 集成 (OkHttp multipart) | 1 天 |
| Realtime WebSocket 集成 (OkHttp WS) | 1-2 天 |
| whisper.cpp JNI 集成 + 模型管理 | 2-3 天 |
| UI 开发 (Jetpack Compose) | 1-2 天 |
| 文本优化服务 | 0.5 天 |
| Foreground Service + 后台保活 | 1 天 |
| ColorOS 适配 + 权限引导 | 1 天 |
| 结果输出（复制/分享/输入法） | 1 天 |
| 测试 + 调试 | 2-3 天 |
| **总计** | **12-16 天** |

---

## Part 3: 代码共享策略

### 3.1 可共享的逻辑

分析 WhisperUtil 各模块，跨三平台可共享的逻辑：

| 逻辑领域 | 具体内容 | 共享价值 |
|----------|---------|---------|
| **API 协议层** | OpenAI HTTP/WebSocket 请求构造、响应解析、错误分类 | 高 |
| **状态机** | idle > recording > processing > waitingToSend > idle | 高 |
| **音频验证** | 最小数据量检查、RMS 音量阈值、静音检测 | 中 |
| **文本后处理** | 繁简转换、标签过滤 `[MUSIC]`/`[BLANK_AUDIO]`、文本清理 | 高 |
| **配置管理** | 用户偏好数据模型、API 模式枚举、默认值 | 高 |
| **网络健康检测** | HEAD 请求探测、回退逻辑 | 中 |
| **录音逻辑** | PCM 采集、重采样、编码 | 低（平台 API 差异大） |
| **UI** | 界面 | 不可共享 |

### 3.2 推荐架构

#### 分层架构（适用于独立开发各平台）

```
+--------------------------------------------------+
|                App Layer (各平台独立)               |
| macOS: NSStatusItem  iOS: SwiftUI  Android: Compose|
+--------------------------------------------------+
|                Platform Layer (各平台独立)           |
| 音频采集   快捷键/触发   文字输入   权限管理           |
+--------------------------------------------------+
|              Shared Business Logic                 |
| 状态机  API协议  文本处理  配置模型  网络检测           |
+--------------------------------------------------+
```

### 3.3 跨平台框架对比（针对此项目）

| 维度 | KMP | Flutter | React Native |
|------|-----|---------|-------------|
| **语言** | Kotlin (共享) + Swift (iOS UI) | Dart | TypeScript |
| **与现有 Swift 代码复用** | 可通过 expect/actual 桥接 | 0% | 0% |
| **音频能力** | 需 platform-specific 实现 | 插件质量参差不齐 | 需 Native Module |
| **WhisperKit 集成** | iOS: 直接调用，Android: JNI | 需要 Platform Channel | 需要 Native Module |
| **whisper.cpp 集成** | Android: JNI | C FFI 可行但复杂 | 需要 Native Module |
| **WebSocket** | Ktor (跨平台) | dart:io WebSocket | 有库可用 |
| **UI** | Compose Multiplatform (稳定) | Flutter Widget (成熟) | RN Components |
| **包大小** | 较小 | 较大 (~15MB runtime) | 较大 |
| **学习曲线** | 低（已会 Kotlin） | 中（学 Dart） | 中（学 RN 生态） |
| **2026 生态成熟度** | 生产就绪 | 成熟 | 成熟但音频弱 |

### 3.4 最终建议：原生各平台独立开发

**不推荐跨平台框架，理由：**

1. **项目规模小：** 总共约 15 个源文件，业务逻辑不超过 3000 行。跨平台框架的接入成本 > 代码复写成本
2. **核心是平台 API：** 音频采集（AVAudioEngine vs AudioRecord）、音频编码（AVAudioFile vs MediaCodec）、本地推理（WhisperKit vs whisper.cpp）——每一项都是深度平台集成，跨平台框架帮不上忙
3. **UI 极简：** 一个录音按钮 + 结果显示 + 设置页。用原生 SwiftUI/Compose 各写一遍比接入跨平台框架更快
4. **维护成本：** 跨平台框架本身的版本升级、平台兼容性问题反而增加长期维护负担

**如果未来确实需要共享逻辑：**

最实际的做法是把 API 协议层和文本处理用 Kotlin 写一遍（Android 原生用），用 Swift 写一遍（macOS/iOS 共享）。两边各 200-300 行代码，比引入 KMP 基础设施更简单。

如果项目规模膨胀到 10+ 个文件的纯业务逻辑（不含平台代码），再考虑 KMP 共享 Android/iOS 业务层。

---

## Part 4: 自动化部署

### 4.1 Android 一键构建部署（推荐方案）

最简单有效的方案是 Gradle + ADB 脚本，不需要 Fastlane：

```bash
#!/bin/bash
# deploy-android.sh -- 一键构建并部署到 OnePlus

set -e

PROJECT_DIR="/path/to/WhisperUtilAndroid"
cd "$PROJECT_DIR"

echo "=== 构建 Debug APK ==="
./gradlew assembleDebug

echo "=== 安装到设备 ==="
adb install -r app/build/outputs/apk/debug/app-debug.apk

echo "=== 启动应用 ==="
adb shell am start -n com.whisperutil/.MainActivity

echo "=== 部署完成 ==="
```

#### 进阶：实时日志

```bash
# 部署后立即查看日志
adb logcat -s WhisperUtil:* --pid=$(adb shell pidof com.whisperutil) 2>/dev/null
```

#### Android Studio 快捷方式

直接用 Android Studio 的 Run 按钮（或 Shift+F10）即可完成构建+部署+启动+日志。对于日常开发，这比脚本更方便。

### 4.2 iOS 自动化部署

#### Xcode 命令行构建 + 安装

```bash
#!/bin/bash
# deploy-ios.sh

set -e

PROJECT_DIR="/path/to/WhisperUtilIOS"

echo "=== 构建 ==="
xcodebuild -project "$PROJECT_DIR/WhisperUtil.xcodeproj" \
  -scheme WhisperUtil -configuration Debug \
  -destination 'platform=iOS,name=My iPhone' \
  build

echo "=== 安装到设备 ==="
# 使用 ios-deploy (brew install ios-deploy)
ios-deploy --bundle "$HOME/Library/Developer/Xcode/DerivedData/WhisperUtil-*/Build/Products/Debug-iphoneos/WhisperUtil.app"
```

或者直接用 Xcode 的 Run（Cmd+R）部署到连接的 iPhone。

#### Fastlane（TestFlight 分发时使用）

```ruby
# fastlane/Fastfile
platform :ios do
  lane :beta do
    build_app(scheme: "WhisperUtil")
    upload_to_testflight
  end
end
```

```bash
# 一键提交 TestFlight
fastlane beta
```

### 4.3 macOS 现有流程保持不变

当前的 `xcodebuild` + `open` 流程已经是最简方案，不需要改动。

### 4.4 统一构建脚本（三平台）

```bash
#!/bin/bash
# deploy.sh -- 统一部署入口
# 用法: ./deploy.sh [macos|ios|android]

case "$1" in
  macos)
    echo "=== 部署 macOS ==="
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
      -project WhisperUtil.xcodeproj -scheme WhisperUtil -configuration Debug build
    osascript -e 'tell application "WhisperUtil" to quit' 2>/dev/null; sleep 1
    open ~/Library/Developer/Xcode/DerivedData/WhisperUtil-*/Build/Products/Debug/WhisperUtil.app
    ;;
  ios)
    echo "=== 部署 iOS ==="
    xcodebuild -project WhisperUtilIOS/WhisperUtil.xcodeproj \
      -scheme WhisperUtil -configuration Debug \
      -destination 'platform=iOS,id=auto' build
    ios-deploy --bundle ~/Library/Developer/Xcode/DerivedData/WhisperUtil-*/Build/Products/Debug-iphoneos/WhisperUtil.app
    ;;
  android)
    echo "=== 部署 Android ==="
    cd WhisperUtilAndroid && ./gradlew assembleDebug
    adb install -r app/build/outputs/apk/debug/app-debug.apk
    adb shell am start -n com.whisperutil/.MainActivity
    ;;
  *)
    echo "用法: $0 [macos|ios|android]"
    exit 1
    ;;
esac

echo "=== 完成 ==="
```

### 4.5 CI/CD（未来扩展）

如果需要自动化构建和分发，推荐：

| 平台 | 工具 | 用途 |
|------|------|------|
| macOS | GitHub Actions (macOS runner) | 构建 + 公证 |
| iOS | GitHub Actions + Fastlane | 构建 + TestFlight |
| Android | GitHub Actions | 构建 + Firebase App Distribution |

但对于个人项目，本地脚本已足够。

---

## 附录：参考资源

### 开源 Whisper Android 项目

- [WhisperKit Android (argmaxinc)](https://github.com/argmaxinc/WhisperKitAndroid) -- 官方 Android 版，Qualcomm NPU 加速，早期阶段
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) -- 最成熟的 C/C++ 实现，含 Android JNI 示例
- [Whisper (F-Droid)](https://f-droid.org/packages/org.woheller69/whisper/) -- 基于 whisper.cpp 的 Android IME
- [whisper_android (TFLite)](https://github.com/vilassn/whisper_android) -- TensorFlow Lite 实现
- [whisper.tflite](https://github.com/nyadla-sys/whisper.tflite) -- 优化的 TFLite 模型
- [Handy](https://github.com/cjpais/Handy) -- 开源离线语音转文字 app
- [openai-realtimeapi-android-agent](https://github.com/klomash/openai-realtimeapi-android-agent) -- OpenAI Realtime API Android 集成示例

### WhisperKit (iOS/macOS)

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) -- Apple 平台本地推理
- [WhisperKit Android Benchmarks](https://huggingface.co/spaces/argmaxinc/whisperkit-android-benchmarks) -- Android 性能基准

### Kotlin Multiplatform

- [KMP 2026 现状](https://volpis.com/blog/is-kotlin-multiplatform-production-ready/) -- 生产就绪评估
- [KMP Roadmap (JetBrains)](https://blog.jetbrains.com/kotlin/2025/08/kmp-roadmap-aug-2025/) -- 官方路线图
- [Compose Multiplatform](https://www.jetbrains.com/compose-multiplatform/) -- 跨平台 UI

### Android 后台限制

- [Don't Kill My App - OnePlus](https://dontkillmyapp.com/oneplus) -- OnePlus 后台应用限制和解决方案
- [Don't Kill My App - Oppo](https://dontkillmyapp.com/oppo) -- ColorOS 后台限制（OnePlus 合并后参考）

### 音频 API

- [Android AudioRecord](https://developer.android.com/reference/android/media/AudioRecord) -- 底层音频采集 API
- [OkHttp WebSocket](https://square.github.io/okhttp/features/websocket/) -- Android WebSocket 客户端
- [Canopas: Stream Live Audio via WebSocket](https://canopas.com/android-send-live-audio-stream-from-client-to-server-using-websocket-and-okhttp-client-ecc9f28118d9) -- 实战教程

### 部署工具

- [Fastlane](https://docs.fastlane.tools/) -- iOS/Android 自动化构建分发
- [ios-deploy](https://github.com/ios-control/ios-deploy) -- 命令行安装 iOS app

---

## 总结与优先级建议

| 平台 | 工作量 | 难度 | 建议优先级 |
|------|-------|------|-----------|
| **iOS** | 5-7 天 | 低 | **第一优先** -- 代码复用率最高，Swift/SwiftUI 直接迁移 |
| **Android** | 12-16 天 | 中 | **第二优先** -- 需要 Kotlin 重写 + whisper.cpp JNI 集成 |

**执行路线图：**

1. **Week 1**: iOS 版本 -- 复制 macOS 项目，新建 iOS target，适配 AVAudioSession + SwiftUI UI
2. **Week 2-3**: Android 版本 -- Kotlin 项目，先做 Cloud + Realtime 模式（纯 HTTP/WS）
3. **Week 3-4**: Android 本地模式 -- 集成 whisper.cpp，ColorOS 适配和测试
