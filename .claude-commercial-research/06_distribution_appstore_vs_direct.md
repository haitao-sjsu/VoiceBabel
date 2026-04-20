# WhisperUtil 分发方式调研：Mac App Store vs 直接下载

> 调研日期：2026-03-26
> 基于 WhisperUtil 实际代码库的系统 API 依赖分析

---

## Part 1: WhisperUtil 系统 API 依赖逐项分析

### 1.1 AVAudioEngine / AVFoundation（麦克风录音）

**文件**: `Audio/AudioRecorder.swift`
**用途**: 通过 `AVAudioEngine.inputNode` + `installTap` 实时采集麦克风音频，`AVAudioConverter` 降采样至 16kHz/24kHz。

**沙盒状态**: ✅ 允许（需 entitlement）

需要添加 `com.apple.security.device.audio-input` 和 `com.apple.security.device.microphone` 两个 entitlement。用户首次使用时系统弹出麦克风权限对话框，授权后正常工作。这是 App Store 应用的标准做法，大量 App Store 应用使用此 API。

---

### 1.2 AudioObjectGetPropertyData / CoreAudio（设备枚举与占用检测）

**文件**: `Audio/AudioRecorder.swift` — `checkMicrophoneAvailability()`
**用途**: 查询默认输入设备 (`kAudioHardwarePropertyDefaultInputDevice`) 和设备是否正在被使用 (`kAudioDevicePropertyDeviceIsRunningSomewhere`)。

**沙盒状态**: ✅ 允许

CoreAudio 设备枚举是只读操作，不涉及控制其他进程。沙盒应用可以正常查询音频设备属性。配合 `com.apple.security.device.audio-input` entitlement 即可使用。

---

### 1.3 CGEvent（键盘模拟 — 文本输入）

**文件**: `Utilities/TextInputter.swift` — `pressKey()`, `typeCharacter()`, `pasteText()`
**用途**:
- `CGEvent(keyboardEventSource:virtualKey:keyDown:)` 创建键盘事件
- `CGEvent.post(tap: .cghidEventTap)` 将模拟按键注入系统事件流
- 用于模拟 Cmd+V 粘贴、Return 键发送、以及 keyboard 模式下的逐字符输入

**沙盒状态**: ❌ 严重受限

这是 WhisperUtil 在沙盒环境下的**核心障碍**。具体表现：

1. **`CGEvent.post()` 需要 Accessibility（辅助功能）权限**。沙盒应用无法获得完整的辅助功能权限——`AXIsProcessTrusted` 始终返回 `false`，系统偏好设置中也无法手动添加沙盒应用到辅助功能列表。
2. Apple Developer Forums 明确指出：「sandboxed apps cannot control other apps, and posting keyboard or mouse events using functions like CGEventPost is not allowed from a sandboxed app」。
3. 有开发者报告：虽然 `CGEvent.post()` 在某些场景下使用独立的权限机制（显示为「辅助功能」权限但实际是一个有限的子集），可以在沙盒中工作，但**行为不一致且不可靠**。Apple 没有提供明确的沙盒 entitlement 来支持此功能。
4. App Store 审核可能因为应用请求「keystroke access」而直接被拒绝。

**影响范围**: WhisperUtil 的**核心功能**——将转录结果自动输入到当前活跃窗口——完全依赖 `CGEvent.post()`。包括：
- 剪贴板模式：模拟 Cmd+V
- 键盘模式：逐字符模拟输入
- 自动发送：模拟 Return 键
- 这三个功能全部失效 = 应用失去主要价值

---

### 1.4 NSEvent.addGlobalMonitorForEvents（全局快捷键监听）

**文件**: `HotkeyManager.swift` — `startMonitoring()`
**用途**: 监听 `flagsChanged`（Option 键手势检测）和 `keyDown`（ESC 键取消），即使应用不在前台也能响应。

**沙盒状态**: ⚠️ 需要替代方案

- `NSEvent.addGlobalMonitorForEvents` 在沙盒中需要 Accessibility 权限才能工作。如前所述，沙盒应用无法可靠获得此权限。
- **替代方案**: 改用 `CGEventTap`（以 `listenOnly` 模式创建），它需要的是 **Input Monitoring（输入监控）** 权限而非 Accessibility 权限。Input Monitoring 权限对沙盒应用和 App Store 应用都是可用的。
- 相关 API: `CGPreflightListenEventAccess()` 检查权限，`CGRequestListenEventAccess()` 请求权限。
- macOS 10.15+ 支持沙盒应用使用 `CGEventTap`。

**结论**: 可以通过代码重构解决，但需要将 HotkeyManager 从 `NSEvent` 全局监听器迁移到 `CGEventTap` 方案。工作量中等。

---

### 1.5 CGWindowListCopyWindowInfo（系统听写检测）

**文件**: `Audio/AudioRecorder.swift` — `isDictationActive()`
**用途**: 遍历所有窗口信息，检查是否存在 `DictationIM` 进程的窗口，以判断系统听写是否激活。

**沙盒状态**: ⚠️ 功能受限

- 从 macOS Mojave (10.14) 开始，`CGWindowListCopyWindowInfo` 在没有 Screen Recording（屏幕录制）权限的情况下，返回的窗口信息是**不完整的**（只能看到自己进程的窗口和一些系统窗口）。
- 沙盒应用可以调用此 API，不会崩溃，但获取到的信息可能不足以检测到 DictationIM 窗口。
- 这不会导致应用崩溃，只会导致听写冲突检测功能失效。

**影响**: 低。这只是一个辅助性的冲突检测功能，失效后最坏情况是用户在系统听写同时使用时可能遇到麦克风冲突，但不影响核心功能。可以降级为仅使用 CoreAudio 设备占用检测。

---

### 1.6 AXIsProcessTrustedWithOptions（辅助功能权限检查）

**文件**: `Utilities/TextInputter.swift` — `checkAccessibilityPermission()`
**用途**: 检查应用是否拥有辅助功能权限，必要时弹出系统授权提示。

**沙盒状态**: ❌ 不可用

沙盒应用中 `AXIsProcessTrusted` 始终返回 `false`，且系统不会弹出授权对话框。用户也无法在「系统设置 → 隐私与安全性 → 辅助功能」中手动添加沙盒应用。这是 Apple 的设计意图——沙盒应用不应控制其他应用。

---

### 1.7 NSPasteboard（剪贴板访问）

**文件**: `Utilities/TextInputter.swift` — `pasteText()`
**用途**: 保存原剪贴板内容 → 写入转录文本 → 模拟 Cmd+V → 恢复原剪贴板。

**沙盒状态**: ✅ 允许（但有未来风险）

NSPasteboard 在沙盒中可以正常使用，不需要特殊 entitlement。但需要注意：

- **macOS 16 (2026)**: Apple 正在引入剪贴板隐私保护功能。当应用以编程方式读取通用剪贴板（非用户交互触发）时，系统会向用户弹出警告。WhisperUtil 恢复原剪贴板内容的操作 (`pasteboard.string(forType: .string)`) 可能触发此警告。
- 但即使触发警告，功能仍然可用，只是用户体验会受影响。

**注意**: 即使剪贴板读写正常，WhisperUtil 仍然需要 `CGEvent.post()` 来模拟 Cmd+V 完成粘贴操作，所以单独解决剪贴板问题没有意义。

---

### 1.8 网络访问（URLSession / WebSocket）

**文件**: `Services/ServiceCloudOpenAI.swift`, `Services/ServiceRealtimeOpenAI.swift`, `Services/ServiceTextCleanup.swift`, `Utilities/NetworkHealthMonitor.swift`
**用途**: HTTP 请求 OpenAI API、WebSocket 连接、NWPathMonitor 网络状态监控。

**沙盒状态**: ✅ 允许（需 entitlement）

添加 `com.apple.security.network.client` entitlement 即可。这是最常见的沙盒 entitlement 之一，几乎所有联网应用都会声明。NWPathMonitor 也不需要额外 entitlement。

---

### 1.9 NSSound（系统提示音）

**文件**: `RecordingController.swift` — `playStartSound()`, `playStopSound()`
**用途**: 播放 "Tink" 和 "Pop" 系统声音作为录音开始/结束提示。

**沙盒状态**: ✅ 允许

系统自带音效播放不受沙盒限制。

---

### 1.10 WhisperKit（本地模型推理）

**文件**: `Services/ServiceLocalWhisper.swift`
**用途**: 本地 Whisper 模型加载和推理。模型首次使用时从网络下载到本地。

**沙盒状态**: ⚠️ 需验证

- 模型文件存储路径需要在沙盒容器内（`~/Library/Containers/<bundle-id>/`）
- WhisperKit 使用 CoreML 推理，CoreML 在沙盒中可正常工作
- 模型下载需要 `com.apple.security.network.client` entitlement
- 需要验证 WhisperKit 的文件 I/O 操作是否都在沙盒容器内完成

---

### API 兼容性汇总表

| API | 用途 | 沙盒兼容性 | 影响程度 |
|-----|------|-----------|---------|
| AVAudioEngine | 麦克风录音 | ✅ 需 entitlement | 无影响 |
| AudioObjectGetPropertyData | 设备枚举 | ✅ 允许 | 无影响 |
| **CGEvent.post()** | **键盘模拟/文本输入** | **❌ 不可用** | **致命** |
| NSEvent.addGlobalMonitor | 全局热键 | ⚠️ 需重构为 CGEventTap | 中等工作量 |
| CGWindowListCopyWindowInfo | 听写检测 | ⚠️ 功能受限 | 低影响 |
| **AXIsProcessTrusted** | **辅助功能权限** | **❌ 不可用** | **致命** |
| NSPasteboard | 剪贴板 | ✅ 允许 | 无影响 |
| URLSession / WebSocket | 网络请求 | ✅ 需 entitlement | 无影响 |
| NWPathMonitor | 网络监控 | ✅ 允许 | 无影响 |
| NSSound | 提示音 | ✅ 允许 | 无影响 |
| WhisperKit/CoreML | 本地推理 | ⚠️ 需验证路径 | 低风险 |

---

## Part 2: App Sandbox 对 WhisperUtil 的影响

### 2.1 会完全失效的功能

| 功能 | 原因 |
|------|------|
| **自动输入转录结果到当前窗口** | CGEvent.post() 被阻止，无法模拟键盘事件 |
| **Cmd+V 粘贴模式** | CGEvent.post() 被阻止 |
| **键盘逐字模拟输入模式** | CGEvent.post() 被阻止 |
| **自动发送（模拟 Return 键）** | CGEvent.post() 被阻止 |
| **辅助功能权限检查/请求** | AXIsProcessTrusted 始终返回 false |

**总结**: WhisperUtil 最核心的用户价值——「说话后文字自动出现在当前输入框中」——在沙盒中完全不可用。

### 2.2 需要修改的功能

| 功能 | 修改方案 |
|------|---------|
| 全局 Option 键热键 | 从 NSEvent 全局监听器迁移到 CGEventTap (listenOnly)，需 Input Monitoring 权限 |
| 系统听写冲突检测 | 降级为仅使用 CoreAudio 设备占用检测，放弃窗口枚举方式 |
| WhisperKit 模型存储 | 确保模型路径使用沙盒容器目录 |

### 2.3 沙盒下可行的替代方案？

如果一定要上 App Store，文本输出只能改为以下方式之一：

1. **仅复制到剪贴板，不自动粘贴**: 转录完成后将文本写入剪贴板，显示通知提示用户手动 Cmd+V。这大幅降低了用户体验，需要用户每次都多做一步操作。
2. **macOS 系统输入法方案**: 理论上可以注册为系统输入法 (Input Method)，但开发复杂度极高，且输入法在沙盒中也有诸多限制。
3. **Accessibility API 的 Automation 子集**: 通过 AppleScript/System Events 发送按键，但这在沙盒中同样被阻止（需要 `com.apple.security.scripting-targets` entitlement 且只能针对特定应用）。

**结论**: 没有可行的沙盒替代方案能达到当前 CGEvent 方式的用户体验。

### 2.4 竞品的做法

#### SuperWhisper
- **同时提供** App Store 版本和直接下载版本
- App Store 版本功能受限（不提供完整的键盘模拟功能，仅提供实验性的 keystroke 模拟且只支持 US QWERTY 布局）
- 主推直接下载版本，提供完整功能
- 直接下载版需要用户授予辅助功能权限

#### VoiceInk
- **同时提供** App Store 版本和直接下载版本（tryvoiceink.com）
- 开源项目 (GitHub)
- App Store 版本同样面临沙盒限制

#### Wispr Flow
- 在 App Store 上架
- 作为 AI 语音键盘应用，可能使用了不同的输入方式

---

## Part 3: Mac App Store 分发

### 优势

1. **发现性**: 用户可以在 App Store 搜索到应用，降低获客成本
2. **信任度**: Apple 审核过的应用天然获得用户信任
3. **自动更新**: Apple 处理所有更新分发，无需自建更新系统
4. **安装/卸载体验**: 用户熟悉的一键操作
5. **支付基础设施**: 内置购买、订阅管理，支持全球支付
6. **沙盒安全**: 对用户来说是安全保障（对开发者是限制）
7. **Family Sharing**: 家庭共享支持

### 劣势

1. **15-30% 佣金**: 小开发者第一年 15%（Small Business Program），之后或超过 100 万美元后 30%
2. **沙盒限制**: 如 Part 1 所述，WhisperUtil 的核心功能被阻止
3. **审核延迟**: 每次更新需要审核（通常 1-3 天，有时更长）
4. **拒绝风险**: 应用可能因各种原因被拒，包括使用辅助功能 API、键盘模拟等
5. **Entitlement 限制**: 部分 entitlement 需要向 Apple 申请特殊许可
6. **定价限制**: App Store 定价必须在 Apple 指定的价格梯度内
7. **元数据要求**: 截图、描述、分类等需要符合规范

### 必要条件

- Apple Developer Program 会员（$99/年）
- 完整的 App Sandbox 支持
- App Review Guidelines 合规
- 需要的 entitlements:
  - `com.apple.security.app-sandbox` (必须)
  - `com.apple.security.device.audio-input` (麦克风)
  - `com.apple.security.network.client` (网络)
  - Input Monitoring 权限（用于 CGEventTap 热键）

---

## Part 4: 直接下载分发

### 优势

1. **无沙盒限制**: CGEvent、Accessibility API 完全可用，WhisperUtil 所有功能正常运行
2. **无佣金**: 100% 收入归开发者
3. **完全系统访问**: 辅助功能、全局事件监听、窗口枚举等
4. **快速迭代**: 无审核流程，修改后立即发布
5. **灵活定价**: 不受 App Store 价格梯度限制
6. **灵活授权**: 可实现一次购买/订阅/Freemium 等任意模式

### 劣势

1. **公证 (Notarization) 要求**: macOS Catalina 以来必须经过 Apple 公证，否则 Gatekeeper 阻止运行
2. **用户信任成本**: 部分用户对非 App Store 应用有戒心
3. **无内置更新**: 需要自行集成 Sparkle 等更新框架
4. **发现性差**: 用户无法从 App Store 搜索发现应用，依赖其他渠道推广
5. **Gatekeeper 警告**: 首次打开时可能出现安全提示（公证后可减轻）
6. **支付系统**: 需要自行集成 Stripe、Paddle、Gumroad 等支付服务
7. **权限教育**: 需要引导用户手动授予辅助功能权限

### 必要条件

#### 证书与签名
- Apple Developer Program 会员（$99/年，同一账号可同时用于 App Store 和直接分发）
- **Developer ID Application Certificate**: 用于代码签名
- **Developer ID Installer Certificate**: 如果使用 .pkg 安装包
- 启用 **Hardened Runtime**（公证要求）

#### 公证流程
```bash
# 1. 构建并签名
xcodebuild -project WhisperUtil.xcodeproj -scheme WhisperUtil \
  -configuration Release archive -archivePath WhisperUtil.xcarchive

# 2. 导出为 .app（使用 Developer ID 签名）
xcodebuild -exportArchive -archivePath WhisperUtil.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath ./export

# 3. 创建 DMG 或 ZIP
create-dmg ./export/WhisperUtil.app ./WhisperUtil.dmg
# 或
ditto -c -k --keepParent ./export/WhisperUtil.app WhisperUtil.zip

# 4. 提交公证
xcrun notarytool submit WhisperUtil.dmg \
  --apple-id "developer@example.com" \
  --password "app-specific-password" \
  --team-id "TEAM_ID" \
  --wait

# 5. Staple 公证凭证到 DMG
xcrun stapler staple WhisperUtil.dmg
```

#### 自动更新 (Sparkle)
- 集成 Sparkle 框架（当前最流行的 macOS 更新框架，https://sparkle-project.org/）
- 生成 EdDSA 密钥对，公钥写入 Info.plist (`SUPublicEDKey`)
- 托管 appcast.xml（更新元数据）和 DMG 文件
- 推荐托管方式: GitHub Releases（免费、可靠、CDN 加速）
- Sparkle 支持增量更新（delta updates），只更新改变的文件

#### 分发托管
- **GitHub Releases**: 免费，适合开源项目
- **自有网站**: 需要域名和托管（如 Cloudflare Pages + R2 存储）
- **第三方**: MacUpdate、Softpedia 等（增加曝光但控制力弱）

---

## Part 5: 混合方案分析

### 5.1 双版本策略

可以同时发布 App Store 版本（功能受限）和直接下载版本（完整功能）：

| 功能 | App Store 版 | 直接下载版 |
|------|-------------|-----------|
| 麦克风录音 | ✅ | ✅ |
| 语音转文字 (Cloud/Local/Realtime) | ✅ | ✅ |
| 全局 Option 键热键 | ✅ (CGEventTap) | ✅ (NSEvent) |
| **自动输入到当前窗口** | ❌ 仅复制到剪贴板 | ✅ 完整 CGEvent |
| **自动发送 (Enter)** | ❌ | ✅ |
| 系统听写冲突检测 | ⚠️ 仅 CoreAudio | ✅ 完整 |
| 翻译 | ✅ | ✅ |
| 文本优化 | ✅ | ✅ |

### 5.2 竞品的混合实践

- **SuperWhisper**: 采用混合方案。App Store 版主要用作引流和建立品牌可信度，完整功能推荐用户从官网下载。
- **VoiceInk**: 也采用混合方案，同时在 App Store 和官网提供下载。
- **1Password、Alfred、Bartender** 等知名工具类应用也曾采用类似策略。

### 5.3 维护成本

维护两个版本的额外成本：
1. **条件编译**: 使用 `#if APPSTORE` 编译标记区分功能
2. **两套 entitlement 文件**: App Store 版需要沙盒 entitlement，直接下载版不需要
3. **两条构建管线**: 分别构建、签名、分发
4. **两次测试**: 需要分别测试两个版本的功能
5. **用户支持**: 需要区分用户使用的版本来诊断问题

对于当前阶段的 WhisperUtil，维护两个版本的额外成本可能不值得，除非：
- App Store 版能带来显著的用户增长
- 有足够的时间/精力维护两条管线

---

## Part 6: 最终建议

### 推荐方案: 直接下载分发（当前阶段）

**核心理由**:

WhisperUtil 的产品价值 = **「说话即输入」**——用户按下热键说话，文字自动出现在当前输入框中。这个核心体验**100% 依赖于 CGEvent.post() 和辅助功能权限**，而这两者在 App Sandbox 中都被完全阻止，没有可行的替代方案。

如果去掉自动输入功能，WhisperUtil 就变成了一个「语音转文字后复制到剪贴板」的工具，与系统自带听写功能的差异大幅缩小，产品竞争力严重削弱。

### 直接下载分发 -- 实施步骤

#### 第一步: Apple Developer Program
- 注册/确认 Apple Developer Program 会员（$99/年）
- 生成 Developer ID Application Certificate（通过 Xcode → Settings → Accounts）

#### 第二步: 配置代码签名
```
在 Xcode 中:
1. Targets → WhisperUtil → Signing & Capabilities
2. Team: 选择你的 Developer ID
3. Signing Certificate: Developer ID Application
4. 启用 Hardened Runtime
5. 添加 Hardened Runtime exceptions（如果需要）:
   - com.apple.security.cs.allow-unsigned-executable-memory (WhisperKit 可能需要)
```

#### 第三步: 集成 Sparkle 自动更新
1. 在 Xcode 中: File → Add Package Dependencies → 输入 `https://github.com/sparkle-project/Sparkle`
2. 生成 EdDSA 密钥:
   ```bash
   ./bin/generate_keys  # Sparkle 自带工具
   ```
3. 将公钥添加到 Info.plist: `SUPublicEDKey`
4. 设置 appcast URL: `SUFeedURL` → 如 `https://github.com/yourname/WhisperUtil/releases/latest/download/appcast.xml`
5. 在 AppDelegate 中添加 Sparkle 更新检查

#### 第四步: 构建与公证自动化
创建发布脚本（可集成到 GitHub Actions）:
```bash
#!/bin/bash
set -e

VERSION=$1
ARCHIVE_PATH="build/WhisperUtil.xcarchive"
EXPORT_PATH="build/export"
DMG_PATH="build/WhisperUtil-${VERSION}.dmg"

# 构建 Release
xcodebuild -project WhisperUtil.xcodeproj -scheme WhisperUtil \
  -configuration Release archive -archivePath "$ARCHIVE_PATH"

# 导出
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$EXPORT_PATH"

# 创建 DMG
create-dmg "$EXPORT_PATH/WhisperUtil.app" "$DMG_PATH"

# 公证
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "WhisperUtil-Notarize" --wait

# Staple
xcrun stapler staple "$DMG_PATH"

# 生成 Sparkle appcast
./bin/generate_appcast build/
```

#### 第五步: 分发托管
- **推荐**: GitHub Releases（免费、全球 CDN、支持 HTTPS）
- 每次发版上传 DMG + 更新 appcast.xml
- 创建简单的落地页（可使用 GitHub Pages）

#### 第六步: 用户引导
应用首次启动时需要引导用户授权：
1. **麦克风权限**: 系统自动弹出（标准流程）
2. **辅助功能权限**: 需要引导用户到「系统设置 → 隐私与安全性 → 辅助功能」手动添加应用。建议在应用内提供清晰的图文引导。
3. **Input Monitoring**: 如果使用 CGEventTap 监听热键，系统会弹出请求

### 未来考虑: App Store 版作为补充

当以下条件满足时，可以考虑追加 App Store 版本:
1. 直接下载版已稳定，用户基数达到一定规模
2. 有时间维护两条构建管线
3. App Store 版明确定位为「轻量版」或「试用版」，引导用户下载完整版
4. 或者 Apple 未来放宽沙盒对 Accessibility API 的限制（可能性极低）

### 关于开源

如果 WhisperUtil 选择开源（参考 VoiceInk），直接下载分发是自然选择：
- 用户可以从源码自行构建（无需证书和公证）
- 开发者签名版通过 GitHub Releases 分发
- 社区贡献加速开发
- 开源本身就是最好的信任背书

---

## 参考资料

- [Apple: Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Signing Mac Software with Developer ID](https://developer.apple.com/developer-id/)
- [Apple: Distributing software on macOS](https://developer.apple.com/macos/distribution/)
- [Apple Developer Forums: Accessibility permission in sandboxed app](https://developer.apple.com/forums/thread/707680)
- [Apple Developer Forums: Accessibility Permission In Sandbox For Keyboard](https://developer.apple.com/forums/thread/789896)
- [Apple Developer Forums: App Store rejection (keystrokes)](https://developer.apple.com/forums/thread/133929)
- [Apple Developer Forums: CGEventPost doesn't work in 10.14](https://developer.apple.com/forums/thread/103992)
- [Why aren't the most useful Mac apps on the App Store?](https://alinpanaitiu.com/blog/apps-outside-app-store/)
- [Accessibility Permission in macOS (2025)](https://jano.dev/apple/macos/swift/2025/01/08/Accessibility-Permission.html)
- [Mac App Store vs Direct Distribution (2026)](https://www.hendoi.in/blog/mac-app-store-vs-direct-distribution-macos-app-2026)
- [Distributing Mac apps outside the App Store](https://www.rambo.codes/posts/2021-01-08-distributing-mac-apps-outside-the-app-store)
- [Jesse Squires: To distribute in the Mac App Store, or not](https://www.jessesquires.com/blog/2021/06/02/to-distribute-in-the-mac-app-store-or-not/)
- [Sparkle: open source software update framework for macOS](https://sparkle-project.org/)
- [Code Signing and Notarization: Sparkle and Tears (2025)](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)
- [SuperWhisper on App Store](https://apps.apple.com/us/app/superwhisper/id6471464415)
- [VoiceInk on App Store](https://apps.apple.com/us/app/voiceink-ai-dictation/id6751431158)
- [VoiceInk on GitHub](https://github.com/Beingpax/VoiceInk)
- [AeroSpace: CGEvent.tapCreate for global hotkeys](https://github.com/nikitabobko/AeroSpace/issues/1012)
- [macOS 16 clipboard privacy changes](https://9to5mac.com/2025/05/12/macos-16-clipboard-privacy-protection/)
