# WhisperUtil Git 版本控制与 CI/CD 方案

---

## Part 1: 引入 Git 版本控制

### 1.1 初始化 Git 仓库

```bash
cd /Users/longhaitao/Documents/1_Project_Claude_WhisperUtil_Swift

# 初始化
git init

# 创建 .gitignore（见下节）

# 首次提交
git add -A
git commit -m "Initial commit: WhisperUtil macOS menu bar speech-to-text tool"
```

### 1.2 .gitignore 推荐配置

根据项目实际文件结构，推荐以下 `.gitignore`：

```gitignore
# ============================================================
# macOS
# ============================================================
.DS_Store
._*
.Spotlight-V100
.Trashes

# ============================================================
# Xcode - 构建产物
# ============================================================
build/
DerivedData/
*.xcodeproj/xcuserdata/
*.xcworkspace/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/
*.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist
*.moved-aside
*.pbxuser
!default.pbxuser
*.mode1v3
!default.mode1v3
*.mode2v3
!default.mode2v3
*.perspectivev3
!default.perspectivev3

# ============================================================
# Swift Package Manager
# ============================================================
.build/
.swiftpm/
Package.resolved

# ============================================================
# 敏感文件 - API 密钥
# ============================================================
Config/EngineeringOptions.swift

# ============================================================
# 日志
# ============================================================
*.log
whisperutil.log

# ============================================================
# Claude Code 工作文件（可选保留）
# ============================================================
# .claude-research/ 和 .claude-plan/ 包含有价值的技术文档，建议提交
# .claude/settings.local.json 包含本地权限配置，不提交
.claude/settings.local.json
.claude/.DS_Store
```

### 1.3 敏感文件处理方案

**当前问题**：`Config/EngineeringOptions.swift` 直接硬编码了 OpenAI API Key。

**推荐方案：.gitignore + 模板文件**（最适合个人项目的简单方案）

1. **将 `EngineeringOptions.swift` 加入 .gitignore**（已在上面配置）
2. **创建模板文件 `Config/EngineeringOptions.swift.template`**，提交到 git：

```swift
// EngineeringOptions.swift.template
// 复制此文件为 EngineeringOptions.swift 并填入你的 API 密钥
// EngineeringOptions.swift 已被 .gitignore 忽略，不会提交

import Foundation

enum EngineeringOptions {
    static let apiKey = "YOUR_OPENAI_API_KEY_HERE"
    static let enableSilenceDetection = true
    static let enableAudioCompression = true
    static let whisperModel = "gpt-4o-transcribe"
    static let localWhisperModel = "openai_whisper-large-v3-v20240930_626MB"
    static let enableCloudFallback = true
    static let realtimeDeltaMode = true
    static let enableTraditionalToSimplified = true
    static let enableTagFiltering = true
    static let translationMethod = "two-step"
    static let translationSourceLanguageFallback = "zh"
    static let inputMethod = "clipboard"
    static let typingDelay: TimeInterval = 0
    static let maxRecordingDuration: TimeInterval = 600
}
```

3. **新机器 clone 后的操作**：
```bash
cp Config/EngineeringOptions.swift.template Config/EngineeringOptions.swift
# 然后编辑填入 API Key
```

**为什么不推荐其他方案**：

| 方案 | 适用场景 | 对本项目的问题 |
|------|---------|--------------|
| 环境变量 | 服务端应用 | macOS 桌面应用无法可靠读取环境变量，需要修改代码架构 |
| git-secret | 多人团队 | 一个人用太重了，依赖 GPG |
| Keychain | 生产级应用 | 需要改代码，增加复杂度，对个人开发过度设计 |
| Xcode Build Settings | 中型项目 | 可以考虑，但 .template 方案更直观 |

**重要提醒**：当前 API Key `sk-proj-eCDKn...` 已经出现在源文件中。如果这个仓库将来意外公开，这个 key 会泄露。建议：
- 初始化 git 之前确认 .gitignore 已就位
- 如果不放心，去 OpenAI 后台 rotate 一次 key

### 1.4 初始提交策略

推荐分两次提交，保持历史清晰：

```bash
# 第一步：确保 .gitignore 先就位
git add .gitignore
git commit -m "Add .gitignore"

# 第二步：提交所有源码
git add -A
git commit -m "Initial commit: WhisperUtil v1.0

macOS menu bar speech-to-text tool supporting three modes:
- Local (WhisperKit) offline transcription
- Cloud (gpt-4o-transcribe) HTTP API
- Realtime (WebSocket) streaming transcription"
```

### 1.5 远程仓库选择

| 选项 | 优势 | 劣势 | 推荐 |
|------|------|------|------|
| **GitHub 私有仓库（免费）** | 无限私有仓库、2000 min/月 Actions、生态最好 | 文件 <100MB、仓库建议 <1GB | **首选** |
| Gitea 自建 | 完全控制、无限制 | 需要维护服务器 | 非必要 |
| GitLab 私有 | 功能全面 | 生态不如 GitHub | 不推荐 |

**推荐 GitHub 私有仓库**。对于个人 Swift 项目，免费额度完全够用。

```bash
# 创建远程仓库后
git remote add origin git@github.com:YOUR_USERNAME/WhisperUtil.git
git push -u origin main
```

### 1.6 分支策略

**对于独立开发者，不要搞复杂的 Git Flow，推荐最简单的两级策略**：

```
main ──────────────────────────────────── 稳定版本
  └── feature/xxx ── 开发分支 ── merge ──┘
```

- `main` 始终保持可编译、可运行
- 日常开发直接在 `main` 上 commit 也完全可以（小改动）
- 大改动（如新增 iOS 版本、重构架构）开 feature 分支
- 不需要 develop、release、hotfix 等分支
- 用 tag 标记里程碑版本：`git tag v1.0`

---

## Part 2: 多 Mac 开发同步

### 2.1 代码同步（Git Push/Pull）

这是最核心的同步手段，日常工作流：

```
MacBook Air (移动开发)          Mac Studio (桌面开发)
     |                              |
     |-- git commit                 |
     |-- git push                   |
     |                              |-- git pull
     |                              |-- 开发...
     |                              |-- git commit
     |                              |-- git push
     |-- git pull                   |
     +-- 继续开发...                 +--
```

**关键习惯**：
- 切换设备前 **必须 commit + push**
- 切换设备后 **必须 pull**
- 保持工作区干净，避免跨设备冲突

**EngineeringOptions.swift 同步**：由于被 .gitignore 忽略，需要手动在两台机器上各放一份。这个文件几乎不改动，一次配置即可。

### 2.2 Xcode 设置同步

| 内容 | 位置 | 同步方式 |
|------|------|---------|
| Scheme（编译方案）| `xcshareddata/xcschemes/` | 已在 git 中，自动同步 |
| 项目设置 | `project.pbxproj` | 已在 git 中，自动同步 |
| 用户偏好（断点等）| `xcuserdata/` | 已被 .gitignore 忽略，各机器独立 |
| Xcode 全局偏好 | `~/Library/Developer/` | 不需要同步，各机器独立配置 |
| 代码片段 | `~/Library/Developer/Xcode/UserData/CodeSnippets/` | 可用 iCloud 或符号链接同步 |

**结论**：项目级别的重要设置通过 git 自然同步，个人偏好不需要同步。

### 2.3 代码签名与证书

**当前情况**：WhisperUtil 是 macOS 菜单栏应用。

**macOS 开发签名**：
- 本地开发测试：使用 "Sign to Run Locally"，无需证书
- 分发给他人：需要 Developer ID 证书
- 证书同步方案：两台 Mac 都登录同一个 Apple ID，Xcode 自动管理

**如果将来做 iOS 版本**：
- Provisioning Profile：Xcode 自动管理（Automatic Signing）
- 两台 Mac 登录同一 Apple Developer 账号即可
- 不需要手动导出/导入证书

### 2.4 开发工具依赖同步

当前项目依赖很少，没有 CocoaPods/Carthage，WhisperKit 可能通过 SPM 管理。

**推荐在项目根目录维护一个 `Brewfile`**（可选）：

```ruby
# Brewfile - 开发环境依赖
# 使用方法：brew bundle

# 开发工具
brew "fastlane"     # CI/CD 自动化（如果使用）
brew "swiftlint"    # 代码风格检查（可选）
```

新机器上执行 `brew bundle` 一键安装所有依赖。

### 2.5 双 Mac 分工建议

| 场景 | 推荐设备 | 原因 |
|------|---------|------|
| 日常编码 | MacBook Air 或 Mac Studio | 都可以，看身在何处 |
| 长时间编译（WhisperKit 模型较大）| Mac Studio | 性能更强，不怕风扇噪音 |
| 本地 CI 构建 | Mac Studio | 可以后台跑，不影响主力机 |
| 移动办公 | MacBook Air | 显然 |
| 调试麦克风/音频 | 哪台都行 | 两台都有麦克风 |

**不需要把 Mac Studio 配置为 build server** -- 对于个人项目，Xcode 直接在本地构建就好。远程构建增加的复杂度远大于收益。

---

## Part 3: CI/CD 流水线

### 3.1 个人开发者需要什么级别的 CI/CD

**核心原则：自动化重复操作，但不要过度工程化。**

对于 WhisperUtil 这样的个人项目，推荐的自动化级别：

```
Level 0: 手动（当前状态）           <-- 你在这里
Level 1: 本地脚本（Makefile）       <-- 推荐先到这里
Level 2: Fastlane 自动化           <-- 有 iOS 版本后考虑
Level 3: GitHub Actions / Xcode Cloud <-- 多平台分发时考虑
```

### 3.2 Level 1：本地自动化脚本（推荐立即实施）

在项目根目录创建 `Makefile`：

```makefile
# Makefile - WhisperUtil 开发自动化
SCHEME = WhisperUtil
PROJECT = WhisperUtil.xcodeproj
CONFIG = Debug
DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData
APP_PATH = $(shell ls -d $(DERIVED_DATA)/WhisperUtil-*/Build/Products/Debug/WhisperUtil.app 2>/dev/null | head -1)
DEVELOPER_DIR = /Applications/Xcode.app/Contents/Developer

.PHONY: build run clean release

# 编译 Debug 版本
build:
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild \
		-project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) build

# 编译并启动（对应 CLAUDE.md 中的标准流程）
run: build
	osascript -e 'tell application "WhisperUtil" to quit' 2>/dev/null; sleep 1
	open "$(APP_PATH)"

# 清理构建产物
clean:
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild \
		-project $(PROJECT) -scheme $(SCHEME) clean

# 编译 Release 版本
release:
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild \
		-project $(PROJECT) -scheme $(SCHEME) -configuration Release build
```

使用方式：
```bash
make build   # 编译
make run     # 编译 + 重启应用
make clean   # 清理
make release # Release 构建
```

### 3.3 Level 2：Fastlane（iOS 版本后考虑）

**安装**：
```bash
brew install fastlane
# 或者更推荐用 Bundler 管理版本
# gem install bundler && bundle init && 在 Gemfile 中添加 fastlane
```

**`fastlane/Fastfile` 示例**：

```ruby
default_platform(:mac)

platform :mac do
  desc "Build Debug"
  lane :build do
    build_mac_app(
      scheme: "WhisperUtil",
      configuration: "Debug",
      skip_codesigning: true,
      skip_package_pkg: true
    )
  end

  desc "Build Release and export"
  lane :release do
    build_mac_app(
      scheme: "WhisperUtil",
      configuration: "Release",
      export_method: "developer-id"
    )
  end
end

# 如果将来有 iOS 版本
platform :ios do
  desc "Push to TestFlight"
  lane :beta do
    build_app(scheme: "WhisperUtil-iOS")
    upload_to_testflight
  end
end
```

### 3.4 Level 3：云端 CI（多平台分发时考虑）

#### GitHub Actions

**免费额度**：2,000 分钟/月（macOS runner 按 10x 计费，相当于约 200 分钟 macOS 构建时间）。

**`.github/workflows/build.yml` 示例**：

```yaml
name: Build WhisperUtil
on:
  push:
    branches: [main]
  pull_request:

jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Create EngineeringOptions from secret
        run: |
          cat > Config/EngineeringOptions.swift << 'SWIFT'
          import Foundation
          enum EngineeringOptions {
              static let apiKey = "${{ secrets.OPENAI_API_KEY }}"
              static let enableSilenceDetection = true
              static let enableAudioCompression = true
              static let whisperModel = "gpt-4o-transcribe"
              static let localWhisperModel = "openai_whisper-large-v3-v20240930_626MB"
              static let enableCloudFallback = true
              static let realtimeDeltaMode = true
              static let enableTraditionalToSimplified = true
              static let enableTagFiltering = true
              static let translationMethod = "two-step"
              static let translationSourceLanguageFallback = "zh"
              static let inputMethod = "clipboard"
              static let typingDelay: TimeInterval = 0
              static let maxRecordingDuration: TimeInterval = 600
          }
          SWIFT

      - name: Build
        run: |
          xcodebuild -project WhisperUtil.xcodeproj \
            -scheme WhisperUtil -configuration Release build

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: WhisperUtil.app
          path: ~/Library/Developer/Xcode/DerivedData/WhisperUtil-*/Build/Products/Release/WhisperUtil.app
```

**注意**：macOS runner 消耗分钟数是 Linux 的 10 倍。每月 200 分钟 macOS 构建，如果每次 build 2 分钟，大约够 100 次构建。对个人项目足够。

#### Xcode Cloud

**免费额度**：Apple Developer Program 会员包含 25 小时/月计算时间（约 150 次构建，每次 10 分钟）。

**优势**：
- 原生集成 Xcode，配置极简
- 自动管理签名和证书
- 支持直接发布到 TestFlight / App Store
- 不需要维护 YAML 配置

**劣势**：
- 只支持 Apple 平台
- 自定义程度不如 GitHub Actions
- Debug 构建问题比较困难

**推荐**：如果只做 Apple 平台（macOS + iOS），Xcode Cloud 是最省事的选择。

### 3.5 一键部署方案

#### macOS App 部署到两台 Mac

**最简单方案：git pull + make run**

```bash
# 在目标 Mac 上
cd ~/Projects/WhisperUtil
git pull
make run
```

不需要更复杂的部署方案。macOS 桌面应用直接从源码编译即可。

**如果想分发编译好的 .app（不在目标机器上编译）**：

```bash
# 在构建机上
make release
# 打包 .app
cd ~/Library/Developer/Xcode/DerivedData/WhisperUtil-*/Build/Products/Release/
zip -r WhisperUtil.zip WhisperUtil.app
# 传到另一台 Mac（AirDrop / scp / 共享文件夹）
scp WhisperUtil.zip user@mac-studio:~/Desktop/
```

#### iOS App 部署到 iPhone

```bash
# 方案 A：Xcode 直连
# 在 Xcode 中选择你的 iPhone，Cmd+R 运行

# 方案 B：TestFlight（需要 App Store Connect 配置）
fastlane ios beta

# 方案 C：命令行安装 .ipa
xcodebuild -project WhisperUtil.xcodeproj -scheme WhisperUtil-iOS \
  -configuration Debug -destination 'id=YOUR_DEVICE_UDID' install
```

#### Android App 部署（简述）

如果将来有跨平台版本（参考跨平台调研报告）：

```bash
# Flutter / KMP 构建后
adb install -r build/app/outputs/flutter-apk/app-debug.apk
# 或
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

---

## Part 4: 实施建议

### 4.1 优先级路线图

```
立即做（30 分钟）
|-- 1. 创建 .gitignore
|-- 2. 创建 EngineeringOptions.swift.template
|-- 3. git init + 首次提交
+-- 4. 创建 GitHub 私有仓库 + push

一周内做（1 小时）
|-- 5. 创建 Makefile
+-- 6. 在新 Mac 上 clone + 配置开发环境

有需要时做
|-- 7. 设置 Xcode Cloud（开始 iOS 开发时）
|-- 8. 设置 Fastlane（需要自动发布 TestFlight 时）
+-- 9. 设置 GitHub Actions（需要自动化测试时）
```

### 4.2 最小可用 vs 完整方案

| 内容 | 最小可用（推荐现在做） | 完整方案（有需要再做） |
|------|----------------------|---------------------|
| 版本控制 | git init + GitHub 私有仓库 | 同左 |
| 敏感文件 | .gitignore + .template | Xcode Build Settings + xcconfig |
| 分支策略 | 只用 main | main + feature 分支 |
| 自动化 | Makefile (build/run) | Fastlane + Xcode Cloud |
| 多 Mac 同步 | git push/pull | 同左（真的不需要更复杂的方案） |
| CI/CD | 无（手动构建） | Xcode Cloud 自动构建 |
| 部署 | make run | Fastlane 一键 TestFlight |

### 4.3 费用概览

| 服务 | 免费额度 | 个人项目是否够用 |
|------|---------|---------------|
| GitHub 私有仓库 | 无限个 | 完全够用 |
| GitHub Actions | 2,000 min/月（macOS 按 10x 计） | 约 200 分钟 macOS 构建，够用 |
| Xcode Cloud | 25 小时/月（Apple Developer 会员附赠） | 约 150 次构建，绰绰有余 |
| Apple Developer Program | $99/年（发布到 App Store 必须） | 如果只本地使用不需要 |
| Fastlane | 免费开源 | N/A |

**结论**：对于个人独立开发者，所有工具的免费额度完全足够，不需要额外花钱。

### 4.4 立即执行的操作清单

以下命令可以直接复制执行：

```bash
cd /Users/longhaitao/Documents/1_Project_Claude_WhisperUtil_Swift

# 1. 创建 .gitignore
# （内容见 1.2 节）

# 2. 创建模板文件
cp Config/EngineeringOptions.swift Config/EngineeringOptions.swift.template
# 然后编辑 template，把 API key 替换为占位符

# 3. 初始化 git
git init
git add .gitignore
git commit -m "Add .gitignore"
git add -A
git commit -m "Initial commit: WhisperUtil macOS menu bar speech-to-text tool"

# 4. 推送到 GitHub（先在 GitHub 网页创建私有仓库）
git remote add origin git@github.com:YOUR_USERNAME/WhisperUtil.git
git branch -M main
git push -u origin main
```

---

## 参考来源

- [GitHub Actions 计费文档](https://docs.github.com/en/actions/concepts/billing-and-usage)
- [GitHub Actions 2026 价格变更](https://github.com/resources/insights/2026-pricing-changes-for-github-actions)
- [Xcode Cloud 概览与定价](https://developer.apple.com/xcode-cloud/)
- [Apple Developer Program 包含 25 小时 Xcode Cloud](https://developer.apple.com/news/?id=ik9z4ll6)
- [GitHub 官方 Swift .gitignore 模板](https://github.com/github/gitignore/blob/main/Swift.gitignore)
- [Fastlane 安装文档](https://docs.fastlane.tools/getting-started/ios/setup/)
- [独立开发者的 Fastlane 配置](https://www.jessesquires.com/blog/2024/01/22/fastlane-for-indies/)
