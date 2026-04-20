# API Key 迁移至 macOS Keychain

## Context

当前 API Key 硬编码在 `Config/EngineeringOptions.swift` 中，存在安全风险（编译产物可通过 `strings` 提取明文）且不便于用户管理。迁移到 macOS Keychain 后，用户通过设置面板输入 API Key，无需接触源码。

参考文档：`.claude-tech-research/11_api_key_management.md`

## 实施步骤

### Step 1: 新增 `Config/KeychainHelper.swift`

Keychain 操作封装，提供 4 个静态方法：
- `save(apiKey:) -> Bool`
- `load() -> String?`
- `delete() -> Bool`
- `exists() -> Bool`

使用 `kSecClassGenericPassword`，service = `"com.whisperutil.api"`，account = `"openai-api-key"`。

需要加入 Xcode 项目文件 (`project.pbxproj`)。

### Step 2: 新增 `Config/ApiKeyValidator.swift`

轻量验证，调用 `GET /v1/models`（不消耗 token）：
- 200 → `.valid`
- 401 → `.invalid("API Key 无效或已过期")`
- 429 → `.valid`（说明 Key 有效，只是限流）
- 其他 → `.invalid("验证失败 (HTTP xxx)")`

需要加入 Xcode 项目文件。

### Step 3: 修改 `Config/SettingsStore.swift`

新增 API Key 管理属性和方法（不使用 UserDefaults，Keychain 专用）：

```
新增属性：
  @Published var apiKeyInput: String = ""          // 输入框绑定
  @Published var hasApiKey: Bool                    // 是否已设置
  @Published var maskedApiKey: String = ""          // "*****kFJ2"
  @Published var apiKeyStatus: ApiKeyStatus = .unchecked
  @Published var isValidatingKey: Bool = false
  @Published var apiKeyVersion: Int = 0            // 变更通知触发器

新增枚举：
  enum ApiKeyStatus { case unchecked, valid, invalid(String) }

新增方法：
  saveApiKey()      — 保存到 Keychain + 自动验证
  clearApiKey()     — 从 Keychain 删除
  validateApiKey()  — 异步调用 ApiKeyValidator

init() 中新增：
  self.hasApiKey = KeychainHelper.exists()
  if let key = KeychainHelper.load() { self.maskedApiKey = maskApiKey(key) }
```

### Step 4: 修改 `Config/Config.swift`

`load()` 中 apiKey 改为仅从 Keychain 读取：

```swift
let apiKey = KeychainHelper.load() ?? ""
```

不需要迁移逻辑，不需要 fallback 到 EngineeringOptions。

### Step 5: 修改 `UI/SettingsView.swift`

在 Form 最顶部新增 "API 密钥" Section：
- 已设置：显示遮盖 Key + 清除按钮 + 验证状态 + 验证按钮
- 未设置：SecureField 输入 + 警告提示 + "获取 API Key" 链接 + 保存按钮

### Step 6: 修改 `AppDelegate.swift`

新增 Combine 订阅监听 `settingsStore.$apiKeyVersion`：
- Key 变更时调用 `rebuildServicesWithNewApiKey()`
- 重建 4 个依赖 API Key 的服务实例
- Key 被清除时自动切换到本地模式

### Step 7: 修改 `RecordingController.swift`

- 新增 `updateServices()` 方法，允许运行时替换服务实例
- 在 `beginRecording()` 中增加无 Key 检查（非本地模式需要 Key）

### Step 8: 清理 `Config/EngineeringOptions.swift`

删除 `apiKey` 字段（不再需要，API Key 完全由 Keychain 管理）。

### Step 9: 删除 `Config/EngineeringOptions.swift.template`

API Key 已迁移到 Keychain，EngineeringOptions 不再包含敏感信息，template 文件失去存在意义。同时将 `Config/EngineeringOptions.swift` 从 `.gitignore` 中移除（不再包含密钥，可以纳入版本控制）。

### Step 10: 更新文档

- `CODEBASE_INDEX.md` — 新增 KeychainHelper.swift 和 ApiKeyValidator.swift 条目

## 不需要修改的文件

- `ServiceCloudOpenAI.swift` — 已通过构造函数注入 apiKey，无需改动
- `ServiceRealtimeOpenAI.swift` — 同上
- `ServiceTextCleanup.swift` — 同上
- `NetworkHealthMonitor.swift` — 同上

## 验证

```bash
make build                    # 编译通过
make dev                      # 启动应用
```

功能验证：
1. 首次启动（无 Key）— 设置面板显示输入框，提示用户输入 API Key
2. 输入并保存 Key — 设置面板显示遮盖的 Key
3. 点击"验证连接" — 显示验证结果
4. 点击"清除" — Key 被删除，自动切换本地模式
5. 重新输入 Key — 保存后服务自动重建
6. 本地模式录音 — 无 Key 也能正常工作
7. 网络模式录音（无 Key）— 提示用户设置 Key
